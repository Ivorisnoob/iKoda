import AVFoundation
import Foundation
import MediaPlayer
import Observation
import os

private let traceEnabled = ProcessInfo.processInfo.environment["KODA_TRACE"] == "1"
private let log = Logger(subsystem: "Koda", category: "Player")

/// Engine events, printed only under `KODA_TRACE=1`.
func trace(_ message: @autoclosure () -> String) {
    guard traceEnabled else { return }
    let line = message()
    print("TRACE", String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)), line)
    log.debug("\(line, privacy: .public)")
}

/// The music player: the queue, the AVFoundation pipeline under it, and the
/// system's Now Playing surfaces.
///
/// `AVQueuePlayer` holds at most two items, the current song and the one the
/// queue says comes next, so a song that ends runs straight into the next
/// without a gap. With crossfade on, the next song waits instead on a player of
/// its own (`standby`); as the current song nears its end that player fades in
/// and becomes the main one, while the old one fades out and is let go. Every load is tagged with the queue occurrence it is for and
/// a generation; anything that comes back after the queue has moved on is
/// dropped rather than applied to whatever is current by then.
@MainActor
@Observable
public final class Player {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Not observed as a whole: any change to it, a repeat tap included, would redraw every
    /// view showing the playing song, which is every song row in the app. Views watch the
    /// parts below instead, each published only when it actually changes.
    @ObservationIgnored public private(set) var queue = PlayQueue() {
        didSet { publishQueue() }
    }
    public private(set) var current: Song?
    /// What plays after the current song, in order.
    public private(set) var upcoming: [QueueItem] = []
    public private(set) var isShuffled = false
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var phase: Phase = .idle
    /// Whether the listener wants sound: true while loading or buffering a song they pressed play on.
    public private(set) var wantsToPlay = false
    /// True while the player waits on the network with the intent to play.
    public private(set) var isBuffering = false
    public private(set) var duration: TimeInterval = 0
    /// Keep playing related songs when the queue runs out.
    public var autoplay = true {
        didSet { persistSettings() }
    }
    /// Bring loud masters down to YouTube's loudness target, so songs play at a similar volume.
    public var normalizesVolume = true {
        didSet {
            persistSettings()
            applyLoudness(currentLoudnessDb)
        }
    }
    /// Keep songs on the phone as they stream, so they start at once next time.
    public var cachesWhileStreaming = true {
        didSet { persistSettings() }
    }
    /// Songs overlap as one ends and the next begins, the old fading out as the new fades in.
    /// Skips get a short fade too, so changing songs never cuts off mid-note.
    public var crossfades = true {
        didSet {
            persistSettings()
            guard crossfades != oldValue else { return }
            // The next song moves between the queue player and the standby player.
            prepareNext()
            armCrossfade()
        }
    }
    /// How long songs overlap when one runs into the next, in seconds.
    public var crossfadeDuration: TimeInterval = 5 {
        didSet {
            persistSettings()
            armCrossfade()
        }
    }
    /// The fade a skip gets with crossfade on: long enough not to click, short enough to feel instant.
    public static let skipFade: TimeInterval = 0.6
    /// Where songs' audio is kept on the phone. A song held whole plays from its file, with
    /// no request to YouTube; nil plays everything from YouTube.
    @ObservationIgnored public var audioStore: AudioStore?

    /// The last known position and when it was sampled; `position(at:)` runs it forward.
    public private(set) var timeAnchor = TimeAnchor(position: 0, date: .distantPast, rate: 0)

    public struct TimeAnchor: Equatable, Sendable {
        public var position: TimeInterval
        public var date: Date
        public var rate: Double
    }

    /// Pause when the current song ends instead of going on, with the next song loaded and ready; for the sleep timer.
    public var stopsAtEndOfSong = false {
        didSet { avPlayer.actionAtItemEnd = stopsAtEndOfSong ? .pause : .advance }
    }

    /// Called when a song starts playing, for history.
    public var onSongStarted: ((Song) -> Void)?
    /// Called every few seconds of actual sound with the seconds heard since the last call, for listening stats.
    public var onListened: ((Song, TimeInterval) -> Void)?
    /// The same two moments for one occurrence in the queue, so a song repeated is a new play: for scrobbling.
    public var onItemStarted: ((QueueItem) -> Void)?
    public var onItemHeard: ((QueueItem, TimeInterval) -> Void)?
    /// Loads artwork for the lock screen; set by the app, which owns image decoding.
    public var artworkLoader: (@MainActor (URL) async -> MPMediaItemArtwork?)?

    public let music: YouTubeMusic
    /// The player the current song plays on. Replaced when a crossfade or a faded skip hands
    /// over to another one; `attach` moves the observers along with it.
    private var avPlayer = AVQueuePlayer()
    /// With crossfade on, the next song loaded and paused on a player of its own.
    private var standby: (player: AVQueuePlayer, item: AVPlayerItem, id: UUID)?
    private let storage: URL?

    /// The occurrence each loaded AVPlayerItem plays.
    private var occurrences: [ObjectIdentifier: UUID] = [:]
    /// Items put behind the current one; becoming current means a song changed at its start.
    private var preloaded: Set<ObjectIdentifier> = []
    /// The item AVFoundation played last, to tell a song that finished from one it dropped.
    private var lastAVItem: AVPlayerItem?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stallWatchdog: Task<Void, Never>?
    /// How long the player may wait on the network, wanting to play, before the song is reloaded.
    var stallTimeout: Duration = .seconds(15)
    /// Test seam: rewrite a stream before it is played.
    var streamRewriter: ((ResolvedStream) -> ResolvedStream)?
    private var generation = 0
    private var nextGeneration = 0
    /// Occurrences already retried after a mid-play failure, so a broken song is skipped rather than looped.
    private var retried: Set<UUID> = []
    private var extendingWithRadio = false
    private var startedReported: UUID?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var nowPlayingArtworkFor: URL?
    private var lastListenedTick: Date?
    /// The playing song's loudness above target, kept so normalization can be switched mid-song.
    private var currentLoudnessDb: Double?
    /// The queue player's volume before any fade: Koda's level with normalization applied.
    private var baseVolume: Float = 1
    /// How far the current song has faded in, 0 to 1; multiplies `baseVolume`.
    private var fadeGain: Float = 1
    private var fadeIn: Task<Void, Never>?
    /// The last main player, playing on by itself while its song fades out.
    private var tail: AVQueuePlayer?
    private var tailFade: Task<Void, Never>?
    /// Fires when the playing song is `crossfadeDuration` from its end.
    private var crossfadeObserver: Any?
    private var lastPersisted = Date.distantPast

    public init(music: YouTubeMusic, storageDirectory: URL? = nil) {
        self.music = music
        storage = storageDirectory
        avPlayer.actionAtItemEnd = .advance
        attach(avPlayer)
        observePlayer()
        configureRemoteCommands()
        restore()
    }

    // MARK: - Reading

    /// Copy into the observed parts what changed in the queue, and nothing else, so a
    /// view is told only when the part it shows is different.
    private func publishQueue() {
        let song = queue.current?.song
        if current != song { current = song }
        if isShuffled != queue.isShuffled { isShuffled = queue.isShuffled }
        if repeatMode != queue.repeatMode { repeatMode = queue.repeatMode }
        let next = queue.upcoming
        if !upcoming.elementsEqual(next) { upcoming = Array(next) }
    }

    public var isMuted = false {
        didSet {
            avPlayer.isMuted = isMuted
            standby?.player.isMuted = isMuted
            tail?.isMuted = isMuted
        }
    }

    /// Koda's own level, 0 to 1, under the system's. The Mac has no system slider an app can
    /// drive, so its volume control sets this; normalization still applies on top.
    public var volume: Float = 1 {
        didSet { applyLoudness(currentLoudnessDb) }
    }

    /// How many songs AVFoundation holds right now: 2 when the next one is preloaded.
    var loadedItemCount: Int { avPlayer.items().count + (standby == nil ? 0 : 1) }
    /// A song is fading out on the side, for tests.
    var isFadingOut: Bool { tail != nil }

    /// The playhead at `date`, run forward from the last sample at the playing rate.
    public func position(at date: Date = Date()) -> TimeInterval {
        let elapsed = timeAnchor.rate > 0 ? date.timeIntervalSince(timeAnchor.date) * timeAnchor.rate : 0
        let value = timeAnchor.position + max(0, elapsed)
        return duration > 0 ? min(value, duration) : value
    }

    // MARK: - Starting playback

    /// Replace the queue and play from `index`.
    public func play(_ songs: [Song], startAt index: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        queue.replace(with: songs, startAt: index, shuffled: shuffled)
        retried = []
        wantsToPlay = true
        loadCurrent(at: 0, fadeIn: fadeOutForSkip())
    }

    /// Play `song` and follow it with its radio.
    public func startRadio(from song: Song) {
        play([song])
        let seed = queue.current?.id
        Task {
            guard let radio = try? await music.radio(for: song.id) else { return }
            guard queue.current?.id == seed else { return }
            queue.append(radio.songs.filter { $0.id != song.id })
            persistQueue()
            prepareNext()
        }
    }

    // MARK: - Transport

    public func togglePlayPause() {
        wantsToPlay ? pause() : resume()
    }

    public func resume() {
        guard queue.current != nil else { return }
        wantsToPlay = true
        activateAudioSession()
        if avPlayer.currentItem == nil || phase != .ready {
            loadCurrent(at: timeAnchor.position)
        } else {
            avPlayer.play()
        }
        updateNowPlaying()
    }

    public func pause() {
        wantsToPlay = false
        finishTail()
        cancelFadeIn()
        avPlayer.pause()
        sampleTime()
        updateNowPlaying()
        persistQueue()
    }

    public func next() {
        guard queue.current != nil else { return }
        if queue.peekNext(automatic: false) == nil {
            extendWithRadio(thenAdvance: true)
            return
        }
        move(to: queue.advance(automatic: false))
    }

    /// Back to the start of the song, or to the song before when already near the start.
    public func previous() {
        if position() > 3 || queue.history.isEmpty && queue.repeatMode == .off {
            seek(to: 0)
            return
        }
        let before = queue.current?.id
        queue.retreat()
        if queue.current?.id == before {
            seek(to: 0)
        } else {
            loadCurrent(at: 0, fadeIn: fadeOutForSkip())
        }
    }

    public func jump(to id: UUID) {
        guard id != queue.current?.id, queue.jump(to: id) else { return }
        wantsToPlay = true
        loadCurrent(at: 0, fadeIn: fadeOutForSkip())
    }

    public func seek(to seconds: TimeInterval) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        timeAnchor = TimeAnchor(position: target, date: Date(), rate: timeAnchor.rate)
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.sampleTime()
                self?.updateNowPlaying()
            }
        }
    }

    /// Jump back (negative) or ahead within the song, held inside its length.
    public func skip(by seconds: TimeInterval) {
        guard queue.current != nil, phase == .ready else { return }
        seek(to: position() + seconds)
    }

    // MARK: - Queue editing

    public func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        queueChanged()
    }

    public func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        queueChanged()
    }

    public func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        queueChanged()
    }

    public func playNext(_ songs: [Song]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(songs)
        if wasEmpty {
            wantsToPlay = true
            loadCurrent(at: 0)
        } else {
            queueChanged()
        }
    }

    public func addToQueue(_ songs: [Song]) {
        let wasEmpty = queue.isEmpty
        queue.append(songs)
        if wasEmpty {
            wantsToPlay = true
            loadCurrent(at: 0)
        } else {
            queueChanged()
        }
    }

    public func remove(_ id: UUID) {
        if queue.remove(id) { queueChanged() }
    }

    public func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpcoming(fromOffsets: source, toOffset: destination)
        queueChanged()
    }

    public func clearUpcoming() {
        queue.clearUpcoming()
        queueChanged()
    }

    /// Stop and empty the queue.
    public func stop() {
        generation += 1
        finishTail()
        cancelFadeIn()
        disarmCrossfade()
        discardStandby()
        avPlayer.removeAllItems()
        occurrences = [:]
        preloaded = []
        lastAVItem = nil
        queue.clear()
        wantsToPlay = false
        isBuffering = false
        phase = .idle
        duration = 0
        timeAnchor = TimeAnchor(position: 0, date: Date(), rate: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistQueue()
    }

    private func queueChanged() {
        persistQueue()
        prepareNext()
        updateRemoteCommandState()
    }

    // MARK: - Loading

    /// Make the queue's current song the one AVFoundation plays, from `position`, fading it
    /// in over `fadeIn` seconds when a skip faded the last one out.
    private func loadCurrent(at position: TimeInterval, fadeIn: TimeInterval = 0) {
        generation += 1
        let token = generation
        disarmCrossfade()
        discardStandby()
        avPlayer.removeAllItems()
        occurrences = [:]
        preloaded = []
        lastAVItem = nil
        queue.trimHistory(keeping: Self.historyLimit)
        guard let item = queue.current else {
            phase = .idle
            return
        }
        // A song shown as playing from the old position would jump; show the new one at once.
        phase = .loading
        isBuffering = wantsToPlay
        duration = item.song.duration ?? 0
        timeAnchor = TimeAnchor(position: position, date: Date(), rate: 0)
        updateNowPlaying()
        persistQueue()
        if wantsToPlay { activateAudioSession() }

        Task {
            do {
                let stream = try await audio(for: item.song)
                guard token == generation, queue.current?.id == item.id else { return }
                let playerItem = makeItem(stream, song: item.song)
                occurrences[ObjectIdentifier(playerItem)] = item.id
                avPlayer.insert(playerItem, after: nil)
                if position > 1 {
                    await avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard token == generation else { return }
                }
                if let total = stream.duration, total > 0 { duration = total }
                applyLoudness(stream)
                if fadeIn > 0 { startFadeIn(over: fadeIn) } else { cancelFadeIn() }
                phase = .ready
                if wantsToPlay { avPlayer.play() }
                sampleTime()
                updateNowPlaying()
                prepareNext()
                armCrossfade()
            } catch is CancellationError {
            } catch {
                guard token == generation, queue.current?.id == item.id else { return }
                handleLoadFailure(error, for: item)
            }
        }
    }

    private func handleLoadFailure(_ error: Error, for item: QueueItem) {
        switch error as? MusicError {
        case .unplayable:
            // A verdict on this video; the rest of the queue is fine.
            skipBroken(item, message: "This song isn't available")
        case .botCheck:
            phase = .failed("YouTube is refusing playback right now. Try again in a little while.")
            isBuffering = false
            wantsToPlay = false
        default:
            phase = .failed("Couldn't load this song. Check your connection and try again.")
            isBuffering = false
            wantsToPlay = false
        }
        updateNowPlaying()
    }

    private func skipBroken(_ item: QueueItem, message: String) {
        guard queue.current?.id == item.id else { return }
        if let next = queue.peekNext(automatic: false), next.id != item.id {
            queue.advance(automatic: false)
            loadCurrent(at: 0)
        } else {
            phase = .failed(message)
            isBuffering = false
            wantsToPlay = false
        }
    }

    /// Keep the next song loaded, matching what the queue says plays next: behind the current
    /// one in AVFoundation's queue, or with crossfade on, on the standby player.
    private func prepareNext() {
        guard phase == .ready, let currentItem = avPlayer.currentItem,
              let currentId = occurrences[ObjectIdentifier(currentItem)], currentId == queue.current?.id else { return }
        let wanted = queue.peekNext(automatic: true)
        let queued = avPlayer.items().dropFirst()
        if crossfades {
            removeFromQueuePlayer(queued)
            if let wanted, standby?.id == wanted.id { return }
        } else {
            discardStandby()
            if let wanted, queued.count == 1, let loaded = queued.first, occurrences[ObjectIdentifier(loaded)] == wanted.id {
                return
            }
            removeFromQueuePlayer(queued)
        }
        discardStandby()
        nextGeneration += 1
        let token = nextGeneration
        guard let wanted else {
            if autoplay, queue.upcoming.isEmpty, queue.repeatMode == .off { extendWithRadio(thenAdvance: false) }
            return
        }
        let onStandby = crossfades
        Task {
            guard let stream = try? await audio(for: wanted.song) else { return }
            guard token == nextGeneration, queue.current?.id == currentId,
                  queue.peekNext(automatic: true)?.id == wanted.id,
                  let playing = avPlayer.currentItem, occurrences[ObjectIdentifier(playing)] == currentId,
                  avPlayer.items().count == 1, standby == nil, crossfades == onStandby else { return }
            let item = makeItem(stream, song: wanted.song)
            occurrences[ObjectIdentifier(item)] = wanted.id
            preloaded.insert(ObjectIdentifier(item))
            trace("preloaded \(wanted.song.title)\(onStandby ? " on standby" : "")")
            if onStandby {
                // Paused, it still buffers, so it can start the moment the fade does.
                let player = AVQueuePlayer()
                player.isMuted = isMuted
                player.insert(item, after: nil)
                standby = (player, item, wanted.id)
            } else {
                avPlayer.insert(item, after: playing)
            }
        }
    }

    private func removeFromQueuePlayer(_ items: some Sequence<AVPlayerItem>) {
        for stale in items {
            occurrences[ObjectIdentifier(stale)] = nil
            preloaded.remove(ObjectIdentifier(stale))
            avPlayer.remove(stale)
        }
    }

    private func discardStandby() {
        guard let standby else { return }
        occurrences[ObjectIdentifier(standby.item)] = nil
        preloaded.remove(ObjectIdentifier(standby.item))
        standby.player.removeAllItems()
        self.standby = nil
    }

    /// The song's audio: its file when the phone holds all of it, else a stream from YouTube.
    private func audio(for song: Song) async throws -> ResolvedStream {
        if let file = audioStore?.completeStream(song.id) { return file }
        return try await music.stream(for: song.id)
    }

    private func makeItem(_ original: ResolvedStream, song: Song) -> AVPlayerItem {
        let stream = streamRewriter?(original) ?? original
        let asset: AVURLAsset
        if !stream.url.isFileURL, cachesWhileStreaming, streamRewriter == nil, let audioStore,
           let loader = CachingLoader(stream: stream, song: song, store: audioStore) {
            asset = loader.makeAsset()
        } else {
            asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: stream.userAgent])
        }
        let item = AVPlayerItem(asset: asset)
        // AVFoundation reads YouTube's fragmented M4A as twice its real length
        // and plays silence for the second half instead of ending. [verified
        // October 2026: 403.1 s reported for a 201.6 s track] YouTube's own
        // duration is exact, so the item is told where it ends.
        if let duration = stream.duration, duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 1000)
        }
        item.preferredForwardBufferDuration = 30
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    /// Bring loud masters down to YouTube's -14 LUFS target; quiet ones are left alone rather than boosted.
    private func applyLoudness(_ stream: ResolvedStream) {
        applyLoudness(stream.loudnessDb)
    }

    private func applyLoudness(_ loudnessDb: Double?) {
        currentLoudnessDb = loudnessDb
        if normalizesVolume, let db = loudnessDb, db > 0 {
            baseVolume = volume * Float(max(0.4, pow(10, -db / 20)))
        } else {
            baseVolume = volume
        }
        avPlayer.volume = baseVolume * fadeGain
    }

    // MARK: - Crossfade

    /// Watch for the moment the playing song is `crossfadeDuration` from its end. A boundary
    /// observer fires only when playback runs across that moment, so seeking past it doesn't.
    private func armCrossfade() {
        disarmCrossfade()
        guard crossfades, phase == .ready, let item = avPlayer.currentItem,
              let id = occurrences[ObjectIdentifier(item)], item.forwardPlaybackEndTime.isValid else { return }
        let end = item.forwardPlaybackEndTime.seconds
        // A short song keeps most of itself unfaded.
        guard end.isFinite, end > crossfadeDuration * 2 + 10 else { return }
        let at = NSValue(time: CMTime(seconds: end - crossfadeDuration, preferredTimescale: 600))
        crossfadeObserver = avPlayer.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.crossfade(from: id) }
        }
    }

    private func disarmCrossfade() {
        if let crossfadeObserver { avPlayer.removeTimeObserver(crossfadeObserver) }
        crossfadeObserver = nil
    }

    /// The song `id` is about to end: fade it out over what's left while the next song fades
    /// in on the standby player. Only when that is the song the queue will play anyway, which
    /// under repeat one is the same song again, waiting from its start.
    private func crossfade(from id: UUID) {
        guard crossfades, wantsToPlay, !stopsAtEndOfSong,
              let item = avPlayer.currentItem, occurrences[ObjectIdentifier(item)] == id, queue.current?.id == id,
              let standby, standby.id == queue.peekNext(automatic: true)?.id else { return }
        let left = item.forwardPlaybackEndTime.seconds - item.currentTime().seconds
        let fade = min(crossfadeDuration, max(1, left))
        trace("crossfade over \(fade)s")
        switchToStandby(fading: fade)
    }

    /// Make the standby player the main one and play its song, fading the old song out and
    /// the new one in over `fade` seconds (none: straight on).
    private func switchToStandby(fading fade: TimeInterval) {
        guard let next = standby else { return }
        standby = nil
        retireMain(fading: fade)
        adopt(next.player)
        if fade > 0 { startFadeIn(over: fade) } else { cancelFadeIn() }
        avPlayer.play()
        // The new player's item was current from the start, so no change is observed; say it.
        currentItemChanged(ObjectIdentifier(next.item))
    }

    /// A skip with crossfade on: the playing song fades out quickly on the side while a fresh
    /// player loads the next. Returns the fade-in the song that replaces it should get.
    private func fadeOutForSkip() -> TimeInterval {
        guard crossfades, avPlayer.timeControlStatus == .playing else { return 0 }
        retireMain(fading: Self.skipFade)
        adopt(AVQueuePlayer())
        return Self.skipFade
    }

    /// Let the main player go: fading its song out over `fade` seconds when it is playing,
    /// otherwise silenced at once. Its songs stop counting as the queue's.
    private func retireMain(fading fade: TimeInterval) {
        let old = avPlayer
        detach(old)
        for item in old.items() {
            occurrences[ObjectIdentifier(item)] = nil
            preloaded.remove(ObjectIdentifier(item))
        }
        lastAVItem = nil
        itemStatusObservation = nil
        stallWatchdog?.cancel()
        finishTail()
        guard fade > 0, old.timeControlStatus == .playing else {
            old.pause()
            old.removeAllItems()
            return
        }
        let gain = old.volume
        old.actionAtItemEnd = .pause
        tail = old
        tailFade = Task { [weak self] in
            await Self.ramp(over: fade) { progress in
                // Equal power: the two songs together stay as loud as one.
                old.volume = gain * Float(cos(progress * .pi / 2))
            }
            guard !Task.isCancelled else { return }
            self?.finishTail()
        }
    }

    /// `player` becomes the main player, with the observers and settings the main one has.
    private func adopt(_ player: AVQueuePlayer) {
        avPlayer = player
        player.isMuted = isMuted
        player.actionAtItemEnd = stopsAtEndOfSong ? .pause : .advance
        attach(player)
    }

    /// Silence and release the song fading out, if there is one.
    private func finishTail() {
        tailFade?.cancel()
        tailFade = nil
        tail?.pause()
        tail?.removeAllItems()
        tail = nil
    }

    private func startFadeIn(over fade: TimeInterval) {
        fadeIn?.cancel()
        fadeGain = 0
        avPlayer.volume = 0
        fadeIn = Task { [weak self] in
            await Self.ramp(over: fade) { progress in
                guard let self else { return }
                self.fadeGain = Float(sin(progress * .pi / 2))
                self.avPlayer.volume = self.baseVolume * self.fadeGain
            }
        }
    }

    /// Back to full volume at once.
    private func cancelFadeIn() {
        fadeIn?.cancel()
        fadeIn = nil
        fadeGain = 1
        avPlayer.volume = baseVolume
    }

    /// Calls `step` with progress from 0 to 1, about 30 times a second, for `duration` seconds.
    private static func ramp(over duration: TimeInterval, _ step: @MainActor (Double) -> Void) async {
        let start = Date()
        while !Task.isCancelled {
            let progress = min(1, Date().timeIntervalSince(start) / duration)
            step(progress)
            if progress >= 1 { return }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    /// Move to `item` after a skip: instantly when it is the preloaded one, otherwise by loading it.
    private func move(to item: QueueItem?) {
        guard let item else { return }
        wantsToPlay = true
        let queued = avPlayer.items()
        if phase == .ready, let standby, standby.id == item.id {
            switchToStandby(fading: avPlayer.timeControlStatus == .playing ? Self.skipFade : 0)
        } else if phase == .ready, queued.count == 2, occurrences[ObjectIdentifier(queued[1])] == item.id {
            occurrences[ObjectIdentifier(queued[0])] = nil
            avPlayer.advanceToNextItem()
            avPlayer.play()
            // currentItem's observer takes it from here.
        } else {
            loadCurrent(at: 0, fadeIn: fadeOutForSkip())
        }
    }

    /// The queue ran out: append the radio of the last song and carry on.
    private func extendWithRadio(thenAdvance: Bool) {
        guard autoplay, !extendingWithRadio, let last = queue.items.last else {
            if thenAdvance, queue.repeatMode == .off { seek(to: 0); pause() }
            return
        }
        extendingWithRadio = true
        let anchor = queue.current?.id
        Task {
            defer { extendingWithRadio = false }
            guard let radio = try? await music.radio(for: last.song.id) else {
                if thenAdvance { pause() }
                return
            }
            guard queue.current?.id == anchor else { return }
            let known = Set(queue.items.suffix(100).map(\.song.id))
            let fresh = radio.songs.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            queue.append(fresh)
            persistQueue()
            if thenAdvance {
                move(to: queue.advance(automatic: false))
            } else {
                prepareNext()
            }
        }
    }

    // MARK: - Observing AVFoundation

    /// Watch `player` as the main player. Events from a player that is no longer main are
    /// dropped, so a late callback from one fading out never moves the queue.
    private func attach(_ player: AVQueuePlayer) {
        observations.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] player, _ in
            let item = player.currentItem.map(ObjectIdentifier.init)
            let source = ObjectIdentifier(player)
            Task { @MainActor in
                guard let self, ObjectIdentifier(self.avPlayer) == source else { return }
                self.currentItemChanged(item)
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            let source = ObjectIdentifier(player)
            Task { @MainActor in
                guard let self, ObjectIdentifier(self.avPlayer) == source else { return }
                self.timeControlChanged(status)
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicTick() }
        }
    }

    private func detach(_ player: AVQueuePlayer) {
        disarmCrossfade()
        observations.forEach { $0.invalidate() }
        observations = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func observePlayer() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let failed = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            trace("FAILED item error=\(err?.domain ?? "-") \(err?.code ?? 0) \(err?.localizedDescription ?? "") underlying=\((err?.userInfo[NSUnderlyingErrorKey] as? NSError)?.description ?? "-")")
            if let log = (note.object as? AVPlayerItem)?.errorLog()?.events.last { trace("errorLog \(log.errorStatusCode) \(log.errorDomain) \(log.errorComment ?? "")") }
            MainActor.assumeIsolated { self?.itemFailed(failed) }
        }
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemEnded(ended) }
        }
        observeAudioSession()
    }

    /// AVQueuePlayer moved on by itself: the preloaded song is now playing.
    private func currentItemChanged(_ item: ObjectIdentifier?) {
        guard let item, let id = occurrences[item] else { return }
        // Its first time reading can still be the previous item's, so a preloaded song starts its clock at zero.
        let startsFresh = preloaded.remove(item) != nil
        // A preloaded copy of the song already current is repeat one coming round again:
        // a new play for history, stats and Last.fm, though the queue stays where it is.
        let loops = startsFresh && queue.current?.id == id
        if loops { startedReported = nil }
        trace("currentItemChanged fresh=\(startsFresh) loops=\(loops) queueMatches=\(queue.current?.id == id) t=\(avPlayer.currentTime().seconds)")
        let previous = lastAVItem
        lastAVItem = avPlayer.currentItem
        watchStatus(of: avPlayer.currentItem, id: id)
        // AVQueuePlayer drops a song that fails and moves on to the preloaded one.
        // That is not the song finishing, so the queue must not follow it.
        if let previous, ObjectIdentifier(previous) != item,
           let droppedId = occurrences[ObjectIdentifier(previous)], droppedId == queue.current?.id,
           stoppedEarly(previous) {
            let at = previous.currentTime().seconds
            trace("dropped early at \(at)")
            recover(droppedId, at: at.isFinite ? at : position())
            return
        }
        if queue.current?.id != id {
            if queue.peekNext(automatic: true)?.id == id {
                queue.advance(automatic: true)
            } else if !queue.jump(to: id) {
                return
            }
            retried.remove(id)
            queue.trimHistory(keeping: Self.historyLimit)
            if let song = queue.current?.song { duration = song.duration ?? duration }
            Task {
                if let song = queue.current?.song, let stream = try? await audio(for: song) {
                    if let total = stream.duration { duration = total }
                    applyLoudness(stream)
                    updateNowPlaying()
                }
            }
            persistQueue()
        }
        if startsFresh {
            timeAnchor = TimeAnchor(position: 0, date: Date(), rate: Double(avPlayer.rate))
        } else {
            // Our own load of the current song; it may be seeking to a resume position.
            sampleTime()
        }
        updateNowPlaying()
        prepareNext()
        armCrossfade()
        // Running straight on from the last song, the player never stops being "playing",
        // so the new song's start is reported here rather than on a status change.
        if avPlayer.timeControlStatus == .playing { reportStart() }
    }

    /// Every five seconds while playing, and when playback starts or stops.
    private func periodicTick() {
        sampleTime()
        let now = Date()
        let playing = avPlayer.timeControlStatus == .playing
        if playing, let last = lastListenedTick, let song = current {
            // A gap longer than the tick means the app was suspended; that time was not heard.
            let heard = min(now.timeIntervalSince(last), 6)
            onListened?(song, heard)
            if let item = queue.current { onItemHeard?(item, heard) }
        }
        lastListenedTick = playing ? now : nil
        // iOS can end the app in the background without warning; keep the saved position recent.
        if playing, now.timeIntervalSince(lastPersisted) > 20 { persistQueue() }
    }

    /// A song ended with nothing preloaded behind it, so AVQueuePlayer stopped.
    /// When something was preloaded, AVQueuePlayer moves on by itself and
    /// `currentItemChanged` advances the queue; doing it here too would skip a song.
    private func itemEnded(_ item: ObjectIdentifier?) {
        trace("itemEnded known=\(item.flatMap { occurrences[$0] } != nil) items=\(avPlayer.items().count)")
        guard let item, let id = occurrences[item], id == queue.current?.id else { return }
        if stopsAtEndOfSong {
            // actionAtItemEnd was .pause, so AVQueuePlayer stayed on this song; move the queue on, paused.
            stopsAtEndOfSong = false
            wantsToPlay = false
            occurrences[item] = nil
            if queue.advance(automatic: true) != nil {
                loadCurrent(at: 0)
            } else {
                seek(to: 0)
                pause()
            }
            return
        }
        if avPlayer.items().contains(where: { ObjectIdentifier($0) != item && occurrences[ObjectIdentifier($0)] != nil }) { return }
        // Ended without a crossfade (seeked past it, or a short song): the standby song goes straight on.
        if let standby, standby.id == queue.peekNext(automatic: true)?.id {
            occurrences[item] = nil
            switchToStandby(fading: 0)
            return
        }
        occurrences[item] = nil
        if queue.advance(automatic: true) != nil {
            loadCurrent(at: 0)
        } else {
            extendWithRadio(thenAdvance: true)
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        trace("timeControl \(status.rawValue) t=\(avPlayer.currentTime().seconds)")
        isBuffering = wantsToPlay && (status == .waitingToPlayAtSpecifiedRate || phase == .loading)
        armStallWatchdog(status)
        if status == .playing { reportStart() }
        sampleTime()
        updateNowPlaying()
    }

    /// Tell history and Last.fm the current song started, once per occurrence.
    private func reportStart() {
        guard let item = queue.current, startedReported != item.id else { return }
        startedReported = item.id
        onSongStarted?(item.song)
        onItemStarted?(item)
    }

    /// A failure of the song AVFoundation is still on. When it has already moved
    /// past it to the preloaded song, `currentItemChanged` sees that instead.
    private func itemFailed(_ item: ObjectIdentifier?) {
        trace("itemFailed known=\(item.flatMap { occurrences[$0] } != nil) isCurrent=\(item.flatMap { occurrences[$0] } == queue.current?.id)")
        guard let item, let id = occurrences[item], id == queue.current?.id,
              avPlayer.currentItem.map(ObjectIdentifier.init) == item else { return }
        recover(id, at: position())
    }

    /// A broken URL does not always post a failure; the item's status turns failed and the player waits forever.
    private func watchStatus(of item: AVPlayerItem?, id: UUID) {
        itemStatusObservation = item?.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.queue.current?.id == id, self.occurrences.values.contains(id) else { return }
                trace("current item status failed")
                self.recover(id, at: self.position())
            }
        }
    }

    /// Waiting on the network for too long while the listener wants sound: reload the song where it was.
    private func armStallWatchdog(_ status: AVPlayer.TimeControlStatus) {
        stallWatchdog?.cancel()
        guard status == .waitingToPlayAtSpecifiedRate, wantsToPlay, phase == .ready, let id = queue.current?.id else { return }
        // A song that never got going is broken sooner than one that stalled mid-way on a slow network.
        let timeout = avPlayer.currentItem?.status == .readyToPlay ? stallTimeout : stallTimeout * 0.5
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.wantsToPlay, self.queue.current?.id == id,
                  self.avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            trace("stalled, reloading")
            self.recover(id, at: self.position())
        }
    }

    /// Whether `item` stopped short of its end rather than finishing.
    private func stoppedEarly(_ item: AVPlayerItem) -> Bool {
        if item.status == .failed { return true }
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
        let reached = item.currentTime().seconds
        guard end.isFinite, reached.isFinite, end > 0 else { return false }
        return reached < end - 2
    }

    /// A stream refused mid-play is usually a refused identity: retry once from
    /// the same spot with a fresh one, and skip the song if it fails again.
    private func recover(_ id: UUID, at seconds: TimeInterval) {
        guard let current = queue.current, current.id == id else { return }
        // Silence whatever AVQueuePlayer moved on to while this one reloads.
        avPlayer.pause()
        guard retried.insert(id).inserted else {
            skipBroken(current, message: "This song stopped loading")
            return
        }
        generation += 1
        let token = generation
        // A whole file that fails to play is damaged; it is fetched again rather than retried.
        if audioStore?.entry(current.song.id)?.isComplete == true { audioStore?.discard(current.song.id) }
        Task {
            await music.streamFailed(current.song.id)
            guard token == generation, queue.current?.id == id else { return }
            loadCurrent(at: seconds)
        }
    }

    private func sampleTime() {
        let seconds = avPlayer.currentTime().seconds
        trace("sample t=\(seconds) phase=\(phase) status=\(avPlayer.timeControlStatus.rawValue)")
        guard seconds.isFinite, phase == .ready else {
            if timeAnchor.rate != 0 {
                timeAnchor = TimeAnchor(position: position(), date: Date(), rate: 0)
                updateNowPlaying()
            }
            return
        }
        let rate = avPlayer.timeControlStatus == .playing ? Double(avPlayer.rate) : 0
        let fresh = TimeAnchor(position: seconds, date: Date(), rate: rate)
        let drifted = fresh.rate != timeAnchor.rate || abs(position(at: fresh.date) - fresh.position) > 1
        timeAnchor = fresh
        // The Lock Screen runs its own clock from the last published sample. A periodic sample
        // that corrects the rate or the position has to reach it too, or it stays frozen (a
        // rate 0 caught as repeat one came round) while the app's own bar has moved on.
        if drifted { updateNowPlaying() }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        #endif
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    // A call or another app took the audio; remember the intent so it can come back.
                    self.resumeAfterInterruption = self.wantsToPlay
                    self.finishTail()
                    self.avPlayer.pause()
                    self.sampleTime()
                case .ended:
                    if self.resumeAfterInterruption, options.contains(.shouldResume) { self.resume() } else if self.resumeAfterInterruption { self.pause() }
                    self.resumeAfterInterruption = false
                default: break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones out: stop rather than play out loud.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
        #endif
    }

    private var resumeAfterInterruption = false

    // MARK: - Now Playing and remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.togglePlayPause() }; return .success }
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = event.shuffleType != .off
            Task { @MainActor in self?.setShuffle(on) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = switch event.repeatType { case .one: .one; case .all: .all; default: .off }
            Task { @MainActor in self?.setRepeat(mode) }
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func updateRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = switch queue.repeatMode { case .off: .off; case .all: .all; case .one: .one }
    }

    private func updateNowPlaying() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard let song = queue.current?.song else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        var info = infoCenter.nowPlayingInfo ?? [:]
        if info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String != song.id {
            info = [:]
            nowPlayingArtworkFor = nil
        }
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = song.id
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artistLine
        info[MPMediaItemPropertyAlbumTitle] = song.album?.title
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position()
        info[MPNowPlayingInfoPropertyPlaybackRate] = timeAnchor.rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = wantsToPlay ? .playing : .paused
        updateRemoteCommandState()

        if let url = song.artwork?.url(pixels: 600), nowPlayingArtworkFor != url, let loader = artworkLoader {
            nowPlayingArtworkFor = url
            let songId = song.id
            Task {
                guard let artwork = await loader(url) else { return }
                guard queue.current?.song.id == songId else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    // MARK: - Persistence

    private struct Saved: Codable, Sendable {
        var queue: PlayQueue
        var position: TimeInterval
    }

    private var queueFile: URL? { storage?.appending(path: "queue.json") }
    private let saveClock = SaveClock()

    /// How many songs already played stay in the queue, for going back.
    static let historyLimit = 100

    /// Save the queue so the app reopens where it was. Encoding and writing happen off the
    /// main thread, a moment later, and only for the newest state: a run of taps on shuffle
    /// or repeat writes once and never holds up the screen.
    public func persistQueue() {
        lastPersisted = Date()
        guard let queueFile else { return }
        let version = saveClock.next()
        let saved = Saved(queue: queue, position: position())
        let clock = saveClock
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard clock.isNewest(version), let data = try? JSONEncoder().encode(saved), clock.isNewest(version) else { return }
            try? data.write(to: queueFile, options: .atomic)
        }
    }

    /// Save right now, on this thread: for when the app is leaving the screen and may be suspended.
    public func persistQueueNow() {
        lastPersisted = Date()
        guard let queueFile else { return }
        _ = saveClock.next()
        if let data = try? JSONEncoder().encode(Saved(queue: queue, position: position())) {
            try? data.write(to: queueFile, options: .atomic)
        }
    }

    private func persistSettings() {
        UserDefaults.standard.set(autoplay, forKey: "koda.autoplay")
        UserDefaults.standard.set(normalizesVolume, forKey: "koda.normalizeVolume")
        UserDefaults.standard.set(cachesWhileStreaming, forKey: "koda.cacheWhileStreaming")
        UserDefaults.standard.set(crossfades, forKey: "koda.crossfade")
        UserDefaults.standard.set(crossfadeDuration, forKey: "koda.crossfadeDuration")
    }

    /// The last queue comes back paused; nothing loads until play is pressed.
    private func restore() {
        // Both are read before either is set: setting one saves both.
        let defaults = UserDefaults.standard
        let savedAutoplay = defaults.object(forKey: "koda.autoplay") as? Bool
        let savedNormalize = defaults.object(forKey: "koda.normalizeVolume") as? Bool
        let savedCaching = defaults.object(forKey: "koda.cacheWhileStreaming") as? Bool
        let savedCrossfade = defaults.object(forKey: "koda.crossfade") as? Bool
        let savedCrossfadeDuration = defaults.object(forKey: "koda.crossfadeDuration") as? Double
        if let savedAutoplay { autoplay = savedAutoplay }
        if let savedNormalize { normalizesVolume = savedNormalize }
        if let savedCaching { cachesWhileStreaming = savedCaching }
        if let savedCrossfade { crossfades = savedCrossfade }
        if let savedCrossfadeDuration { crossfadeDuration = min(12, max(1, savedCrossfadeDuration)) }
        guard let queueFile, let data = try? Data(contentsOf: queueFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.queue.current != nil else { return }
        queue = saved.queue
        // A queue saved by an older version kept every song ever played.
        queue.trimHistory(keeping: Self.historyLimit)
        duration = queue.current?.song.duration ?? 0
        timeAnchor = TimeAnchor(position: saved.position, date: Date(), rate: 0)
        phase = .idle
        updateNowPlaying()
    }
}

/// Numbers each queue save, so a background write that has been overtaken by a newer
/// save is dropped instead of overwriting it.
final class SaveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0

    func next() -> Int {
        lock.withLock {
            newest += 1
            return newest
        }
    }

    func isNewest(_ version: Int) -> Bool {
        lock.withLock { version == newest }
    }
}

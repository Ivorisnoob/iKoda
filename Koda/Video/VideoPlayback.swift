import AVFoundation
import AVKit
import KodaCore
import SwiftUI

/// The one video player: what's on, its HLS stream on an AVPlayer, the state its controls draw
/// (time, playing, buffering), its settings (quality, speed, captions), picture in picture and
/// full screen, and keeping it out of the music's way: starting a video pauses the songs, and a
/// song starting pauses the video (AppModel). It outlives the watch page: leaving the page keeps
/// the video going in the mini player (the iPhone's tab bar accessory, the Mac's video bar),
/// remembers where each video got to, and at the end moves on to Up Next.
@MainActor
@Observable
final class VideoPlayback {
    private(set) var current: Video?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The picture's shape once known: a portrait video goes full screen upright.
    private(set) var presentationSize: CGSize = .zero
    /// The video is floating in picture in picture: leaving its page doesn't pause it.
    private(set) var isInPictureInPicture = false
    var isFullScreen = false {
        didSet { if isFullScreen != oldValue { choosePictureInPictureSurface() } }
    }
    /// The heights this video comes in, tallest first.
    private(set) var qualities: [Int] = []
    /// The tallest picture allowed for this video, in lines; 0 follows the connection. Each
    /// video starts at the default quality (Settings); the player's menu changes only this one.
    private(set) var quality = 0
    /// Kept between videos, as YouTube keeps it.
    private(set) var speed: Float = 1
    /// The rate while a finger holds the video down; nil when nothing holds it.
    private(set) var boost: Float?
    /// The video's caption languages, from its stream; empty when it has none.
    private(set) var captions: [AVMediaSelectionOption] = []
    private(set) var caption: AVMediaSelectionOption?
    /// Where this video picked up from where it was left, for the "Resumed" note over it.
    private(set) var resumedFrom: TimeInterval?
    /// The video played to its end.
    private(set) var hasEnded = false
    /// Videos the listener lined up (Play Next, Add to Queue): they play in this order when the
    /// one on ends, before anything YouTube suggests, and whether or not Autoplay is on.
    private(set) var queue: [Video] = []
    /// YouTube's own pick for after this video, from its watch page.
    private(set) var suggested: Video?
    /// What plays when this one ends: the queue's first, else YouTube's pick.
    var upNext: Video? { queue.first ?? suggested }
    /// Seconds until `upNext` starts, counting down after the end; nil when nothing is counting.
    private(set) var autoplayCountdown: Int?
    /// The last move to the next video that the player made by itself, so the page showing the
    /// one before follows it.
    private(set) var autoplayed: (from: String, to: Video)?
    /// The id of the watch page on screen, if any: with the playing video's page showing, the
    /// mini player steps away.
    private(set) var pageOnScreen: String?

    let player = AVPlayer()
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// The frames the timeline previews under the pointer, from the stream's answer.
    private(set) var storyboard: VideoStoryboard?
    /// Chapters by video, as watch pages bring them in (a page can load before or after its
    /// video starts).
    private(set) var knownChapters: [String: [VideoChapter]] = [:]
    /// The playing video's chapters, in order; empty when it has none.
    var chapters: [VideoChapter] { current.flatMap { knownChapters[$0.id] } ?? [] }
    /// Sponsor, self-promotion and subscribe-reminder parts SponsorBlock marked in the playing
    /// video, skipped as they come (only with Skip Sponsors on).
    private(set) var sponsorSegments: [SponsorSegment] = []
    /// The part just skipped, for the player to say so and offer to go back.
    private(set) var sponsorSkip: SponsorSkip?
    /// Whether SponsorBlock is asked about each video (Settings → Videos, off by default).
    @ObservationIgnored var skipsSponsors: () -> Bool = { false }
    @ObservationIgnored private var skippedSegments: Set<String> = []
    /// Where a video asked for at a time (a chapter of one not yet on) starts.
    @ObservationIgnored private var pendingStart: TimeInterval?

    struct SponsorSkip: Equatable {
        let id: String
        let title: String
        let from: TimeInterval
    }
    /// The rates a hold can reach by sliding sideways.
    static let boostRange: ClosedRange<Float> = 1.25...3

    private let music: YouTubeMusic
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var legible: AVMediaSelectionGroup?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPictureDelegate: PictureInPictureDelegate?
    /// The layer picture in picture was last set up for. Kept here rather than read back from
    /// the controller, whose `playerLayer` on the Mac isn't the layer it was made with: comparing
    /// against that made a new controller (a slow call into the system) on every redraw.
    @ObservationIgnored private weak var pictureInPictureLayer: AVPlayerLayer?
    /// Each place the picture is drawn, by role; the one in front is picture in picture's.
    @ObservationIgnored private var surfaces: [SurfaceRole: WeakLayer] = [:]
    /// Where the current watched span began (seeks end one), for the account's history.
    @ObservationIgnored private var spanStart: TimeInterval = 0
    /// Seconds really played of this video, so a glance never counts as a watch.
    @ObservationIgnored private var playedSeconds: TimeInterval = 0
    @ObservationIgnored private var lastSpanReport = Date.distantPast
    @ObservationIgnored private var lastProgressSave: TimeInterval = -1
    /// Told when a video starts, for the profile's watched list.
    @ObservationIgnored var onWatch: ((Video) -> Void)?
    @ObservationIgnored var pauseMusic: (() -> Void)?
    /// The quality each video starts at (AppSettings.videoQuality).
    @ObservationIgnored var defaultQuality: () -> Int = { 0 }
    /// Where a video was left, to start it there again (the Library's progress).
    @ObservationIgnored var resumePosition: ((String) -> TimeInterval?)?
    /// How far a video has got: id, position, duration.
    @ObservationIgnored var onProgress: ((String, TimeInterval, TimeInterval) -> Void)?
    /// A span of the video watched, for the account's YouTube history: id, from, to, and whether
    /// the watch has stopped (paused, ended, left).
    @ObservationIgnored var onWatchSpan: ((String, TimeInterval, TimeInterval, Bool) -> Void)?
    /// Whether to move on at the end (AppSettings.autoplaysVideos).
    @ObservationIgnored var autoplays: () -> Bool = { true }

    /// A watch counts for the account's history once this much has really played (Android's 10 s).
    private static let qualifyingSeconds: TimeInterval = 10

    init(music: YouTubeMusic) {
        self.music = music
        player.allowsExternalPlayback = true
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main,
                                                      using: Self.ticker(for: self))
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main,
                                                             using: Self.endWatcher(for: self))
    }

    /// Built outside the main actor's methods: AVFoundation calls it on the main queue, and it
    /// says so before touching the model.
    nonisolated private static func ticker(for playback: VideoPlayback) -> @Sendable (CMTime) -> Void {
        { [weak playback] _ in
            MainActor.assumeIsolated { playback?.tick() }
        }
    }

    nonisolated private static func endWatcher(for playback: VideoPlayback) -> @Sendable (Notification) -> Void {
        { [weak playback] note in
            let item = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { playback?.itemEnded(item) }
        }
    }

    private func tick() {
        let status = player.timeControlStatus
        let playing = status == .playing
        let wasPlaying = isPlaying
        if isPlaying != playing { isPlaying = playing }
        let buffering = status == .waitingToPlayAtSpecifiedRate
        if isBuffering != buffering { isBuffering = buffering }
        let now = player.currentTime().seconds
        if now.isFinite, abs(now - time) > 0.2 { time = now }
        if let item = player.currentItem {
            let length = item.duration.seconds
            if length.isFinite, length != duration { duration = length }
            if item.presentationSize != presentationSize { presentationSize = item.presentationSize }
        }
        guard let id = current?.id, player.currentItem != nil else { return }
        if playing { playedSeconds += 0.25 }
        skipSponsorSegment()
        // Where it got to: every few seconds while it plays, and as it stops.
        if !isLive, duration > 0, abs(time - lastProgressSave) >= 5 || (wasPlaying && !playing) {
            lastProgressSave = time
            onProgress?(id, time, duration)
        }
        if wasPlaying, !playing {
            reportSpan(final: true)
        } else if playing, Date().timeIntervalSince(lastSpanReport) >= 60 {
            // The first report files the video in history as soon as the watch counts; after
            // that, once a minute says how far it has got (and every pause, seek and end), which
            // keeps YouTube's red bar right without pinging it more than needed.
            reportSpan(final: false)
        }
    }

    /// The span since the last report, once the watch has played long enough to count.
    private func reportSpan(final: Bool) {
        guard let id = current?.id, playedSeconds >= Self.qualifyingSeconds else { return }
        let position = time
        // Nothing new since the last report (a pause right after a seek, say).
        guard abs(position - spanStart) >= 0.5 else { return }
        onWatchSpan?(id, spanStart, position, final)
        spanStart = position
        lastSpanReport = Date()
    }

    // MARK: Playing

    /// Start `video`, unless it's already the one on; `startingAt` jumps there (a chapter).
    func play(_ video: Video, startingAt start: TimeInterval? = nil) {
        if current?.id == video.id, player.currentItem != nil || (isLoading && error == nil) {
            if let start {
                if player.currentItem != nil { seek(to: start) } else { pendingStart = start }
            }
            // Back on the same video's page, or the page catching up with an autoplay already
            // loading it: keep the details fresher, don't restart it.
            current = video.merged(over: current)
            return
        }
        finishCurrent()
        loading?.cancel()
        cancelAutoplay()
        player.replaceCurrentItem(with: nil)
        current = video
        error = nil
        isLoading = true
        hasEnded = false
        resumedFrom = nil
        suggested = nil
        queue.removeAll { $0.id == video.id }
        boost = nil
        time = 0
        duration = video.duration ?? 0
        presentationSize = .zero
        qualities = []
        captions = []
        caption = nil
        legible = nil
        storyboard = nil
        sponsorSegments = []
        sponsorSkip = nil
        skippedSegments = []
        pendingStart = start
        quality = defaultQuality()
        spanStart = 0
        playedSeconds = 0
        lastSpanReport = .distantPast
        lastProgressSave = -1
        pauseMusic?()
        loading = Task {
            defer { if current?.id == video.id { isLoading = false } }
            do {
                let stream = try await music.videoStream(video.id)
                guard !Task.isCancelled, current?.id == video.id else { return }
                let item = AVPlayerItem(url: stream.url)
                #if os(iOS)
                item.externalMetadata = Self.metadata(for: video)
                #endif
                item.preferredMaximumResolution = Self.limit(for: quality)
                qualities = stream.qualities
                storyboard = stream.storyboard
                if skipsSponsors(), !stream.isLive { loadSponsorSegments(for: video.id) }
                player.replaceCurrentItem(with: item)
                player.defaultRate = speed
                // Back where it was left, as YouTube does; a live stream is always now.
                if !stream.isLive, let position = resumePosition?(video.id) {
                    await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard current?.id == video.id else { return }
                    time = position
                    spanStart = position
                    lastProgressSave = position
                    resumedFrom = position
                }
                if let start = pendingStart {
                    pendingStart = nil
                    await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard current?.id == video.id else { return }
                    time = start
                    spanStart = start
                    resumedFrom = nil
                }
                Self.activateVideoSession()
                player.play()
                onWatch?(video)
                await loadCaptions(of: item)
            } catch is CancellationError {
            } catch {
                guard current?.id == video.id else { return }
                self.error = (error as? MusicError).map(Self.message) ?? "This video couldn't be played."
            }
        }
    }

    /// Details from the watch page fill in what the list row didn't have.
    func update(_ video: Video) {
        guard current?.id == video.id else { return }
        current = video.merged(over: current)
        #if os(iOS)
        player.currentItem?.externalMetadata = Self.metadata(for: video)
        #endif
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            pauseMusic?()
            cancelAutoplay()
            // At the end, play starts it over.
            if hasEnded || (duration > 0 && time >= duration - 0.5) { seek(to: 0) }
            Self.activateVideoSession()
            player.playImmediately(atRate: boost ?? speed)
        } else {
            player.pause()
        }
        tick()
    }

    func pause() {
        player.pause()
        tick()
    }

    /// Play on if it's paused (a time tapped in a comment starts the video there).
    func resume() {
        if player.currentItem != nil, player.timeControlStatus == .paused { togglePlay() }
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        // A jump ends the span watched so far; what was skipped is never claimed as seen.
        reportSpan(final: false)
        spanStart = target
        time = target
        hasEnded = false
        resumedFrom = nil
        cancelAutoplay()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Chapters and SponsorBlock

    func setChapters(_ chapters: [VideoChapter], for videoId: String) {
        guard knownChapters[videoId] != chapters else { return }
        knownChapters[videoId] = chapters
        // A handful is enough to keep; pages come and go.
        if knownChapters.count > 30, let stale = knownChapters.keys.first(where: { $0 != current?.id && $0 != videoId }) {
            knownChapters[stale] = nil
        }
    }

    private func loadSponsorSegments(for videoId: String) {
        Task {
            let segments = await SponsorBlock.segments(for: videoId)
            guard current?.id == videoId else { return }
            let skipped: Set<SponsorSegment.Category> = [.sponsor, .selfpromo, .interaction]
            sponsorSegments = segments.filter { skipped.contains($0.category) }
        }
    }

    /// Playing into a marked part jumps to its end, once per part, so seeking back into it on
    /// purpose plays it.
    private func skipSponsorSegment() {
        guard isPlaying, !sponsorSegments.isEmpty,
              let segment = sponsorSegments.first(where: { time >= $0.start && time < $0.end - 0.5 && !skippedSegments.contains($0.id) })
        else { return }
        skippedSegments.insert(segment.id)
        seek(to: segment.end)
        sponsorSkip = SponsorSkip(id: segment.id, title: segment.category.title, from: segment.start)
    }

    /// Back to the start of the part just skipped; it then plays.
    func undoSponsorSkip() {
        guard let skip = sponsorSkip else { return }
        sponsorSkip = nil
        seek(to: skip.from)
    }

    func dismissSponsorSkip() {
        sponsorSkip = nil
    }

    /// One frame on or back, while paused (`,` and `.`).
    func step(by frames: Int) {
        guard let item = player.currentItem, !isPlaying else { return }
        item.step(byCount: frames)
    }

    /// The next speed up or down the list (`>` and `<`).
    func stepSpeed(by offset: Int) {
        let index = Self.speeds.firstIndex(of: speed) ?? Self.speeds.firstIndex(of: 1)!
        setSpeed(Self.speeds[min(Self.speeds.count - 1, max(0, index + offset))])
    }

    /// Subtitles on (the listener's language if offered, else the first) or off (`C`).
    func toggleCaptions() {
        if caption != nil { return setCaption(nil) }
        let language = Locale.current.language.languageCode?.identifier
        let preferred = captions.first { $0.locale?.language.languageCode?.identifier == language } ?? captions.first
        setCaption(preferred)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: time + seconds)
    }

    func retry() {
        guard let video = current else { return }
        current = nil
        play(video)
    }

    /// Done with the video: the mini player's close button. Where it got to is kept.
    func stop() {
        finishCurrent()
        loading?.cancel()
        cancelAutoplay()
        player.replaceCurrentItem(with: nil)
        current = nil
        isPlaying = false
        isLoading = false
        error = nil
        suggested = nil
        queue = []
        isFullScreen = false
    }

    /// The last of the old video's progress and history before another replaces it.
    private func finishCurrent() {
        guard let id = current?.id, player.currentItem != nil else { return }
        if !isLive, duration > 0 { onProgress?(id, time, duration) }
        if isPlaying { reportSpan(final: true) }
    }

    /// Muted, kept here as well as on the player so the controls redraw when it changes.
    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    /// The video's own volume (the Mac's controls set it; the iPhone's buttons set the system's),
    /// remembered between videos and launches.
    var volume: Float = UserDefaults.standard.object(forKey: "koda.video.volume") as? Float ?? 1 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "koda.video.volume")
        }
    }

    // MARK: Hold to speed up

    /// A finger came down and stayed: faster until it lifts, from `rate`.
    func startBoost(_ rate: Float) {
        guard player.timeControlStatus != .paused, !isLive else { return }
        setBoost(rate)
    }

    func setBoost(_ rate: Float) {
        // Past 2× HLS needs the item to say it can.
        let ceiling: Float = player.currentItem?.canPlayFastForward == true ? Self.boostRange.upperBound : 2
        let rate = min(max(rate, Self.boostRange.lowerBound), ceiling)
        boost = rate
        player.rate = rate
    }

    func endBoost() {
        guard boost != nil else { return }
        boost = nil
        if player.rate != 0 { player.rate = speed }
    }

    // MARK: Up Next

    /// The watch page knows what YouTube would play next.
    func setUpNext(_ video: Video?, after id: String) {
        guard current?.id == id, video?.id != id else { return }
        suggested = video
    }

    // MARK: Queue

    /// Right after the one playing. With nothing on, it simply plays.
    func queueNext(_ video: Video) {
        guard current != nil else { return play(video) }
        guard video.id != current?.id else { return }
        queue.removeAll { $0.id == video.id }
        queue.insert(video, at: 0)
    }

    /// After everything already lined up.
    func queueLast(_ video: Video) {
        guard current != nil else { return play(video) }
        guard video.id != current?.id, !queue.contains(where: { $0.id == video.id }) else { return }
        queue.append(video)
    }

    /// One of the queued videos now, ahead of its turn. The page showing the video before
    /// follows it, as it follows Up Next.
    func playFromQueue(_ video: Video) {
        guard let from = current?.id, from != video.id else { return play(video) }
        play(video)
        autoplayed = (from, video)
    }

    func isQueued(_ video: Video) -> Bool {
        queue.contains { $0.id == video.id }
    }

    func removeFromQueue(_ ids: Set<String>) {
        queue.removeAll { ids.contains($0.id) }
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
    }

    func moveQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
    }

    func clearQueue() {
        queue = []
    }

    /// The watch page showing `id` is on screen, or went away.
    func pageAppeared(_ id: String) {
        pageOnScreen = id
        choosePictureInPictureSurface()
    }

    func pageDisappeared(_ id: String) {
        if pageOnScreen == id { pageOnScreen = nil }
        choosePictureInPictureSurface()
    }

    /// The playing video's own page is showing: no mini player.
    var isOnItsPage: Bool { current != nil && pageOnScreen == current?.id }

    private func itemEnded(_ item: ObjectIdentifier?) {
        guard let item, let current = player.currentItem, ObjectIdentifier(current) == item else { return }
        hasEnded = true
        time = duration
        endBoost()
        tick()
        if let id = self.current?.id, !isLive, duration > 0 { onProgress?(id, duration, duration) }
        reportSpan(final: true)
        // A queue plays on by itself; YouTube's pick only with Autoplay on.
        guard !queue.isEmpty || autoplays(), !isLive, let id = self.current?.id else { return }
        countdown = Task {
            if upNext == nil {
                // The page was never opened (or hadn't loaded): ask YouTube what's next.
                let page = try? await music.watchPage(id)
                guard !Task.isCancelled, self.current?.id == id else { return }
                suggested = page?.next
            }
            guard upNext != nil else { return }
            for remaining in stride(from: 5, through: 1, by: -1) {
                autoplayCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            playNext()
        }
    }

    /// Up Next now, skipping what's left of the countdown.
    func playNext() {
        guard let next = upNext, let from = current?.id else { return }
        countdown?.cancel()
        countdown = nil
        autoplayCountdown = nil
        play(next)
        autoplayed = (from, next)
    }

    func cancelAutoplay() {
        countdown?.cancel()
        countdown = nil
        autoplayCountdown = nil
    }

    /// A live stream has no end to scrub to.
    var isLive: Bool { current?.isLive == true }

    // MARK: Settings

    /// This video's quality, from the player's menu.
    func setQuality(_ lines: Int) {
        quality = lines
        player.currentItem?.preferredMaximumResolution = Self.limit(for: lines)
    }

    func setSpeed(_ rate: Float) {
        speed = rate
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    /// Captions in `option`'s language, or none.
    func setCaption(_ option: AVMediaSelectionOption?) {
        guard let item = player.currentItem, let legible else { return }
        item.select(option, in: legible)
        caption = option
    }

    private func loadCaptions(of item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), player.currentItem === item else { return }
        legible = group
        captions = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        caption = item.currentMediaSelection.selectedMediaOption(in: group)
    }

    // MARK: Picture in picture

    /// Where the picture can be drawn: the watch page, full screen, or the mini player.
    enum SurfaceRole {
        case page, fullScreen, mini
    }

    private struct WeakLayer {
        weak var layer: AVPlayerLayer?
    }

    /// A surface says where it draws. Cheap when nothing changed: it's called on every redraw.
    func register(_ layer: AVPlayerLayer, as role: SurfaceRole) {
        guard surfaces[role]?.layer !== layer else { return }
        surfaces[role] = WeakLayer(layer: layer)
        choosePictureInPictureSurface()
    }

    /// Picture in picture floats the surface in front: full screen, else the page, else the mini
    /// player. One rule here rather than each surface claiming it: two surfaces both claiming it
    /// took it from each other on every redraw, each time building a new controller.
    private func choosePictureInPictureSurface() {
        let front: SurfaceRole = isFullScreen ? .fullScreen : isOnItsPage ? .page : .mini
        guard let layer = surfaces[front]?.layer ?? surfaces[.page]?.layer else { return }
        // Never pull the source from under a floating video.
        guard pictureInPicture?.isPictureInPictureActive != true else { return }
        attach(layer)
    }

    /// The front picture's layer floats into picture in picture, by the button or on leaving the app.
    private func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pictureInPictureLayer !== layer else { return }
        pictureInPictureLayer = layer
        let controller = AVPictureInPictureController(playerLayer: layer)
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        let delegate = PictureInPictureDelegate { [weak self] active in self?.isInPictureInPicture = active }
        controller?.delegate = delegate
        pictureInPicture = controller
        pictureInPictureDelegate = delegate
    }

    var canPictureInPicture: Bool { pictureInPicture != nil }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.startPictureInPicture()
        }
    }

    // MARK: Helpers

    /// The songs' session is long-form audio, which iOS won't put a picture in picture over; a
    /// video plays as a movie. The songs' player sets its own policy back each time it starts.
    private static func activateVideoSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.routeSharingPolicy != .default || session.mode != .moviePlayback else { return }
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .default)
        try? session.setActive(true)
        #endif
    }

    private static func message(_ error: MusicError) -> String {
        switch error {
        case .unplayable(let reason): reason ?? "This video isn't available."
        case .network: "Couldn't connect. Check your connection and try again."
        case .botCheck: "YouTube is asking Koda to wait a moment. Try again shortly."
        default: "This video couldn't be played."
        }
    }

    /// The largest frame a quality allows. Square, so it caps a portrait video's width the way it
    /// caps a landscape one's height: 720 allows 1280×720 and 720×1280, not 1920×1080.
    private static func limit(for lines: Int) -> CGSize {
        guard lines > 0 else { return .zero }
        let side = (CGFloat(lines) * 16 / 9).rounded(.up)
        return CGSize(width: side, height: side)
    }

    /// The title and channel the system shows for the video: picture in picture, AirPlay, the Lock Screen.
    private static func metadata(for video: Video) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, video.title)]
        if let channel = video.channel?.name { items.append(item(.commonIdentifierArtist, channel)) }
        return items
    }
}

/// Tells the model when picture in picture starts and stops.
private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    let changed: @MainActor (Bool) -> Void

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        changed(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        changed(false)
    }
}

extension Video {
    /// This video's details, keeping what `other` (the same video) knew that this doesn't.
    func merged(over other: Video?) -> Video {
        guard let other, other.id == id else { return self }
        var video = self
        if video.channel?.avatar == nil, let avatar = other.channel?.avatar { video.channel?.avatar = avatar }
        if video.channel == nil { video.channel = other.channel }
        video.thumbnail = video.thumbnail ?? other.thumbnail
        video.duration = video.duration ?? other.duration
        video.views = video.views ?? other.views
        video.published = video.published ?? other.published
        return video
    }
}

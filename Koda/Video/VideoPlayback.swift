import AVFoundation
import AVKit
import KodaCore
import SwiftUI

/// The one video player: what's on, its HLS stream on an AVPlayer, the state its controls draw
/// (time, playing, buffering), its settings (quality, speed, captions), picture in picture and
/// full screen, and keeping it out of the music's way: starting a video pauses the songs, and a
/// song starting pauses the video (AppModel).
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
    var isFullScreen = false
    /// The heights this video comes in, tallest first.
    private(set) var qualities: [Int] = []
    /// The tallest picture allowed, in lines; 0 follows the connection. Kept between videos.
    private(set) var quality = 0
    /// Kept between videos, as YouTube keeps it.
    private(set) var speed: Float = 1
    /// The video's caption languages, from its stream; empty when it has none.
    private(set) var captions: [AVMediaSelectionOption] = []
    private(set) var caption: AVMediaSelectionOption?

    let player = AVPlayer()
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private let music: YouTubeMusic
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var legible: AVMediaSelectionGroup?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private var pictureInPictureDelegate: PictureInPictureDelegate?
    /// Told when a video starts, for the profile's watched list.
    @ObservationIgnored var onWatch: ((Video) -> Void)?
    @ObservationIgnored var pauseMusic: (() -> Void)?
    /// Where the quality choice is kept (AppSettings).
    @ObservationIgnored var onQualityChange: ((Int) -> Void)?

    init(music: YouTubeMusic) {
        self.music = music
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main,
                                                      using: Self.ticker(for: self))
    }

    /// Built outside the main actor's methods: AVFoundation calls it on the main queue, and it
    /// says so before touching the model.
    nonisolated private static func ticker(for playback: VideoPlayback) -> @Sendable (CMTime) -> Void {
        { [weak playback] _ in
            MainActor.assumeIsolated { playback?.tick() }
        }
    }

    private func tick() {
        let status = player.timeControlStatus
        let playing = status == .playing
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
    }

    // MARK: Playing

    /// Start `video`, unless it's already the one on.
    func play(_ video: Video) {
        if current?.id == video.id, player.currentItem != nil {
            // Back on the same video's page: keep the details fresher, don't restart it.
            current = video.merged(over: current)
            return
        }
        loading?.cancel()
        player.replaceCurrentItem(with: nil)
        current = video
        error = nil
        isLoading = true
        time = 0
        duration = video.duration ?? 0
        presentationSize = .zero
        qualities = []
        captions = []
        caption = nil
        legible = nil
        pauseMusic?()
        loading = Task {
            defer { if current?.id == video.id { isLoading = false } }
            do {
                let stream = try await music.videoStream(video.id)
                guard !Task.isCancelled, current?.id == video.id else { return }
                let item = AVPlayerItem(url: stream.url)
                item.externalMetadata = Self.metadata(for: video)
                item.preferredMaximumResolution = Self.limit(for: quality)
                qualities = stream.qualities
                player.replaceCurrentItem(with: item)
                player.defaultRate = speed
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
        player.currentItem?.externalMetadata = Self.metadata(for: video)
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            pauseMusic?()
            // At the end, play starts it over.
            if duration > 0, time >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: speed)
        } else {
            player.pause()
        }
        tick()
    }

    func pause() {
        player.pause()
        tick()
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: time + seconds)
    }

    func retry() {
        guard let video = current else { return }
        current = nil
        play(video)
    }

    /// A live stream has no end to scrub to.
    var isLive: Bool { current?.isLive == true }

    // MARK: Settings

    func setQuality(_ lines: Int) {
        quality = lines
        player.currentItem?.preferredMaximumResolution = Self.limit(for: lines)
        onQualityChange?(lines)
    }

    /// The saved choice, applied from the next video on.
    func restoreQuality(_ lines: Int) {
        quality = lines
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

    /// The inline picture's layer floats into picture in picture, by the button or on leaving the app.
    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pictureInPicture?.playerLayer !== layer else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
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

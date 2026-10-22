import AVFoundation
import AVKit
import KodaCore
import SwiftUI

/// The one video player: what's on, its HLS stream on an AVPlayer, and keeping it out of the
/// music's way. Starting a video pauses the songs; a song starting pauses the video (AppModel).
/// Played through `AVPlayerViewController`, so controls, picture in picture, AirPlay and the
/// Lock Screen are the system's own.
@MainActor
@Observable
final class VideoPlayback {
    private(set) var current: Video?
    private(set) var isLoading = false
    private(set) var error: String?
    /// The video is floating in picture in picture: leaving its page doesn't pause it.
    var isInPictureInPicture = false
    /// The heights this video comes in, tallest first.
    private(set) var qualities: [Int] = []
    /// The tallest picture allowed, in lines; 0 follows the connection. Kept between videos.
    private(set) var quality = 0
    /// Kept between videos, as YouTube keeps it.
    private(set) var speed: Float = 1
    /// The video's caption languages, from its stream; empty when it has none.
    private(set) var captions: [AVMediaSelectionOption] = []
    private(set) var caption: AVMediaSelectionOption?
    @ObservationIgnored private var legible: AVMediaSelectionGroup?
    /// Where the quality choice is kept (AppSettings).
    @ObservationIgnored var onQualityChange: ((Int) -> Void)?
    let player = AVPlayer()

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private let music: YouTubeMusic
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Told when a video starts, for the profile's watched list.
    @ObservationIgnored var onWatch: ((Video) -> Void)?
    @ObservationIgnored var pauseMusic: (() -> Void)?

    init(music: YouTubeMusic) {
        self.music = music
        player.allowsExternalPlayback = true
    }

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

    func pause() {
        player.pause()
    }

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

    /// The largest frame a quality allows. Square, so it caps a portrait video's width the way it
    /// caps a landscape one's height: 720 allows 1280×720 and 720×1280, not 1920×1080.
    private static func limit(for lines: Int) -> CGSize {
        guard lines > 0 else { return .zero }
        let side = (CGFloat(lines) * 16 / 9).rounded(.up)
        return CGSize(width: side, height: side)
    }

    func retry() {
        guard let video = current else { return }
        current = nil
        play(video)
    }

    private static func message(_ error: MusicError) -> String {
        switch error {
        case .unplayable(let reason): reason ?? "This video isn't available."
        case .network: "Couldn't connect. Check your connection and try again."
        case .botCheck: "YouTube is asking Koda to wait a moment. Try again shortly."
        default: "This video couldn't be played."
        }
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

/// The system's video player, inline: its controls, full screen, picture in picture and AirPlay.
struct VideoPlayerView: UIViewControllerRepresentable {
    let playback: VideoPlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== playback.player { controller.player = playback.player }
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let playback: VideoPlayback

        init(playback: VideoPlayback) {
            self.playback = playback
        }

        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            playback.isInPictureInPicture = true
        }

        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            playback.isInPictureInPicture = false
        }
    }
}

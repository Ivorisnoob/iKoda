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
    let player = AVPlayer()

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
        pauseMusic?()
        loading = Task {
            defer { if current?.id == video.id { isLoading = false } }
            do {
                let stream = try await music.videoStream(video.id)
                guard !Task.isCancelled, current?.id == video.id else { return }
                let item = AVPlayerItem(url: stream.url)
                item.externalMetadata = Self.metadata(for: video)
                player.replaceCurrentItem(with: item)
                player.play()
                onWatch?(video)
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

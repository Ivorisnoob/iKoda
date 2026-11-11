import AVFoundation
import KodaCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// YouTube's hover preview, on the Mac: the pointer resting on a thumbnail plays the video inside
/// it, muted, from the start. One at a time; leaving the thumbnail stops it. The stream (one
/// `/player` request) is asked for only after the pointer has rested a moment, so sweeping
/// across a page asks for nothing, and each one is kept for the session.
@MainActor
@Observable
final class VideoHoverPreview {
    /// The video playing in its thumbnail, once its picture is on the way.
    private(set) var videoID: String?
    @ObservationIgnored let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }()
    @ObservationIgnored private var hovered: String?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var streams: [String: URL] = [:]

    /// How long the pointer rests before a preview starts, as YouTube waits.
    private static let delay = Duration.milliseconds(700)

    func hover(_ video: Video, isOver: Bool, music: YouTubeMusic) {
        if isOver {
            guard hovered != video.id, !video.isLive else { return }
            stop()
            hovered = video.id
            starting = Task { [weak self] in
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                await self?.start(video, music: music)
            }
        } else if hovered == video.id {
            stop()
        }
    }

    private func start(_ video: Video, music: YouTubeMusic) async {
        let url: URL
        if let known = streams[video.id] {
            url = known
        } else {
            guard let stream = try? await music.videoStream(video.id), !Task.isCancelled, hovered == video.id else { return }
            streams[video.id] = stream.url
            url = stream.url
        }
        let item = AVPlayerItem(url: url)
        // A thumbnail's worth of picture: quick to start, light on data.
        item.preferredMaximumResolution = CGSize(width: 854, height: 854)
        player.replaceCurrentItem(with: item)
        player.play()
        videoID = video.id
    }

    func stop() {
        starting?.cancel()
        starting = nil
        hovered = nil
        guard videoID != nil || player.currentItem != nil else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoID = nil
    }
}

#if os(macOS)
/// The preview's picture, fading in once its first frame is ready so the thumbnail never
/// flashes black.
struct HoverPreviewSurface: NSViewRepresentable {
    let player: AVPlayer
    @Binding var isReady: Bool

    final class Coordinator {
        var readiness: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        let ready = $isReady
        context.coordinator.readiness = Self.observe(view.playerLayer) { ready.wrappedValue = true }
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.readiness?.invalidate()
        view.playerLayer.player = nil
    }

    /// KVO may call from any thread, so the observer is made outside the main actor.
    nonisolated private static func observe(_ layer: AVPlayerLayer, ready: @escaping @MainActor @Sendable () -> Void) -> NSKeyValueObservation {
        layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in ready() }
        }
    }
}

/// The thumbnail's preview while the pointer rests on it.
struct HoverPreviewLayer: View {
    let video: Video
    @Environment(AppModel.self) private var app
    @State private var isReady = false

    var body: some View {
        if app.videoPreview.videoID == video.id {
            HoverPreviewSurface(player: app.videoPreview.player, isReady: $isReady)
                .opacity(isReady ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: isReady)
                .allowsHitTesting(false)
                .onDisappear { isReady = false }
        }
    }
}
#endif

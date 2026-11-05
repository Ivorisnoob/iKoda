import AVFoundation
import KodaCore
import MediaPlayer
import SwiftUI
import UIKit

/// The playing album's animated cover laid over its still one, as Music shows it: it fades
/// in once the loop's first frame is ready, moves while the music plays and holds its frame
/// while paused. With no animated cover, the setting off, or animated images turned off in
/// Accessibility, nothing is drawn and the still cover shows as always.
struct AnimatedCover: View {
    let song: Song?
    let isPlaying: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @Environment(\.scenePhase) private var scenePhase
    @State private var loop: Loop?
    @State private var isReady = false

    private struct Loop: Equatable {
        /// YouTube's album, so the next song from the same album keeps the loop going.
        var album: String
        var file: URL
    }

    private struct Request: Equatable {
        var songID: String?
        var album: String?
        var art: AppSettings.AnimatedArt
        var allowed: Bool
    }

    var body: some View {
        ZStack {
            if let loop {
                LoopingVideo(file: loop.file, isPlaying: isPlaying && scenePhase == .active) { isReady = true }
                    .id(loop.file)
                    .opacity(isReady ? 1 : 0)
            }
        }
        .animation(.smooth(duration: 0.6), value: isReady)
        .allowsHitTesting(false)
        .task(id: Request(songID: song?.id, album: song?.album?.id, art: app.settings.animatedArt, allowed: playsAnimatedImages)) {
            await find()
        }
    }

    private func find() async {
        let setting = app.settings.animatedArt
        guard let song, let album = song.album?.id, setting != .off, playsAnimatedImages else {
            show(nil)
            return
        }
        // Another album's loop never lingers over this song's cover while its own is looked for.
        if loop?.album != album { show(nil) }
        guard let covers = await app.motionArtwork.covers(for: song, allowsCellular: setting.allowsCellular),
              let file = await app.motionArtwork.loop(covers, shape: .square, pixels: AnimatedCover.pixels,
                                                       allowsCellular: setting.allowsCellular),
              !Task.isCancelled else {
            if !Task.isCancelled { show(nil) }
            return
        }
        show(Loop(album: album, file: file))
    }

    private func show(_ next: Loop?) {
        guard next?.file != loop?.file else {
            loop = next
            return
        }
        isReady = false
        loop = next
    }

    /// One size for every cover: the big cover is about 1000 pixels across on a phone and
    /// less in a Mac window, and one file per album is shared with the Lock Screen.
    static let pixels = 1080
}

/// A muted loop on an AVPlayerLayer. It never keeps the screen awake, never goes to AirPlay
/// and never touches the audio session: the music's own player owns all three.
private struct LoopingVideo: UIViewRepresentable {
    let file: URL
    let isPlaying: Bool
    let onReady: @MainActor @Sendable () -> Void

    final class Coordinator {
        let player: AVQueuePlayer = {
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.allowsExternalPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            return player
        }()
        var looper: AVPlayerLooper?
        var readiness: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = context.coordinator.player
        context.coordinator.looper = AVPlayerLooper(player: context.coordinator.player, templateItem: AVPlayerItem(url: file))
        context.coordinator.readiness = Self.observeReadiness(view.playerLayer, onReady: onReady)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        let player = context.coordinator.player
        if isPlaying, player.timeControlStatus == .paused { player.play() }
        if !isPlaying, player.timeControlStatus != .paused { player.pause() }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.readiness?.invalidate()
        coordinator.looper?.disableLooping()
        coordinator.player.pause()
        coordinator.player.removeAllItems()
    }

    /// KVO may call from any thread, so the observer is made outside the main actor.
    nonisolated private static func observeReadiness(_ layer: AVPlayerLayer, onReady: @escaping @MainActor @Sendable () -> Void) -> NSKeyValueObservation {
        layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in onReady() }
        }
    }
}

/// The animated covers handed to the Lock Screen, square and tall. The system asks for the
/// preview frame and the loop file only when it is about to show them, at the size it wants,
/// so the tall loop is downloaded only if the Lock Screen draws it.
enum LockScreenAnimatedArt {
    static func artwork(for song: Song, app: AppModel) async -> [String: MPMediaItemAnimatedArtwork] {
        let setting = app.settings.animatedArt
        guard setting != .off,
              let covers = await app.motionArtwork.covers(for: song, allowsCellular: setting.allowsCellular) else { return [:] }
        var out: [String: MPMediaItemAnimatedArtwork] = [:]
        out[MPNowPlayingInfoProperty1x1AnimatedArtwork] = make(covers, shape: .square, motion: app.motionArtwork, allowsCellular: setting.allowsCellular)
        if covers.masters[.tall] != nil {
            out[MPNowPlayingInfoProperty3x4AnimatedArtwork] = make(covers, shape: .tall, motion: app.motionArtwork, allowsCellular: setting.allowsCellular)
        }
        return out
    }

    /// The system calls both handlers on its own queues, so they are made outside the main actor.
    nonisolated private static func make(_ covers: MotionArtwork.Covers, shape: MotionArtwork.Shape, motion: MotionArtwork,
                                         allowsCellular: Bool) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: "\(covers.albumID)-\(shape.rawValue)") { size, completion in
            let reply = Reply(send: completion)
            let pixels = Int(max(size.width, size.height * shape.aspect).rounded())
            Task {
                guard let url = covers.preview(shape, pixels: max(pixels, 1)),
                      let (data, _) = try? await URLSession.shared.data(from: url) else {
                    reply.send(nil)
                    return
                }
                reply.send(UIImage(data: data))
            }
        } videoAssetFileURLRequestHandler: { size, completion in
            let reply = Reply(send: completion)
            Task {
                reply.send(await motion.loop(covers, shape: shape, pixels: Int(size.width.rounded()), allowsCellular: allowsCellular))
            }
        }
    }

    /// The system's completion handlers are called exactly once, from whichever thread.
    nonisolated private struct Reply<Value>: @unchecked Sendable {
        let send: (Value?) -> Void
    }
}

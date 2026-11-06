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
    /// Square over the cover; tall for Now Playing's full-screen art on the iPhone.
    var shape: MotionArtwork.Shape = .square
    /// Told whether a loop is showing, so the page can make room for it or give it back.
    var onShow: ((Bool) -> Void)? = nil
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
        var shape: MotionArtwork.Shape
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
        .task(id: Request(songID: song?.id, album: song?.album?.id, art: app.settings.animatedArt, allowed: playsAnimatedImages, shape: shape)) {
            await find()
        }
        .onChange(of: loop != nil && isReady, initial: true) { _, showing in onShow?(showing) }
    }

    private func find() async {
        let setting = app.settings.animatedArt
        guard let song, setting != .off, playsAnimatedImages else {
            show(nil)
            return
        }
        // Another album's loop never lingers over this song's cover while its own is looked for.
        // A song that arrived without its album may still have a cover known by its id.
        if song.album?.id == nil || loop?.album != song.album?.id { show(nil) }
        guard let covers = await app.motionArtwork.covers(for: song, allowsCellular: setting.allowsCellular),
              covers.masters[shape] != nil,
              let file = await app.motionArtwork.loop(covers, shape: shape, pixels: AnimatedCover.pixels,
                                                       allowsCellular: setting.allowsCellular),
              !Task.isCancelled else {
            if !Task.isCancelled { show(nil) }
            return
        }
        show(Loop(album: song.album?.id ?? "apple:\(covers.albumID)", file: file))
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
    /// less in a Mac window, the full-screen art about a phone's width, and one file per
    /// album and shape is shared with the Lock Screen.
    static let pixels = 1080
}

/// Now Playing's full-screen animated art on the iPhone, as Music shows it: the album's tall
/// loop across the top of the screen, under the status bar, its lower part blurring and then
/// melting into the cover's colours so the title and controls sit on it. Drawn only once the
/// loop's first frame is ready; until then, and for albums without one, the square cover shows.
struct FullScreenMotionArt: View {
    let song: Song?
    let isPlaying: Bool
    let onShow: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.width / MotionArtwork.Shape.tall.aspect
            AnimatedCover(song: song, isPlaying: isPlaying, shape: .tall, onShow: onShow)
                .frame(width: geometry.size.width, height: height)
                .clipped()
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: height * 0.42)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .center))
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.76),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The wide Now Playing's animated art (a Mac window, an iPad): the album's tall loop down the
/// whole height of the window, under the title bar, as Music shows it. Beside lyrics or Up Next
/// it rests against the window's leading edge and dissolves towards them, blurring as it fades;
/// alone it stands in the middle and dissolves on both sides. Its foot blurs under the controls.
struct SideMotionArt: View {
    let song: Song?
    let isPlaying: Bool
    /// Lyrics or Up Next are open beside it.
    let beside: Bool
    let onShow: (Bool) -> Void

    /// The art's width in a window `size`: three wide to four tall, leaving room for the panel.
    static func width(in size: CGSize, beside: Bool) -> CGFloat {
        min(size.height * 0.75, size.width * (beside ? 0.6 : 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = Self.width(in: geometry.size, beside: beside)
            AnimatedCover(song: song, isPlaying: isPlaying, shape: .tall, onShow: onShow)
                .frame(width: width, height: geometry.size.height)
                .clipped()
                // Blur gathers towards every edge that fades, so the loop melts rather than stops.
                .overlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask {
                            ZStack {
                                LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black, location: 0.92)],
                                               startPoint: .top, endPoint: .bottom)
                                LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 0.95)],
                                               startPoint: .leading, endPoint: .trailing)
                                if !beside {
                                    LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 0.95)],
                                                   startPoint: .trailing, endPoint: .leading)
                                }
                            }
                        }
                }
                .mask(Self.fade(startPoint: .leading, endPoint: .trailing, both: !beside))
                .mask(Self.fade(startPoint: .top, endPoint: .bottom, both: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: beside ? .leading : .center)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Opaque, then easing out to nothing over the last stretch (at both ends with `both`).
    private static func fade(startPoint: UnitPoint, endPoint: UnitPoint, both: Bool) -> LinearGradient {
        let tail: [Gradient.Stop] = [.init(color: .black, location: 0.62), .init(color: .black.opacity(0.75), location: 0.76),
                                     .init(color: .black.opacity(0.35), location: 0.88), .init(color: .clear, location: 1)]
        guard both else { return LinearGradient(stops: [.init(color: .black, location: 0)] + tail, startPoint: startPoint, endPoint: endPoint) }
        let head = tail.reversed().map { Gradient.Stop(color: $0.color, location: 1 - $0.location) }
        // Both ends over the same span: the head mirrors the tail.
        let squeeze: (Gradient.Stop) -> Gradient.Stop = { .init(color: $0.color, location: $0.location) }
        return LinearGradient(stops: (head.map(squeeze).filter { $0.location < 0.5 } + [.init(color: .black, location: 0.5)]
                                      + tail.filter { $0.location > 0.5 }), startPoint: startPoint, endPoint: endPoint)
    }
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
                let data = await motion.previewImage(covers, shape: shape, pixels: pixels, allowsCellular: allowsCellular)
                reply.send(data.flatMap(UIImage.init(data:)))
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

import AVFoundation
import AVKit
import KodaCore
import SwiftUI
import UIKit

/// The video with Koda's own controls over it, the same inline and full screen: back (inline, on
/// the iPhone), AirPlay, picture in picture and a settings menu (quality, speed, captions) along
/// the top; back 10 s, play/pause and forward 10 s in the middle; a scrubber that follows the
/// finger, the times and full screen along the bottom. They fade after three seconds of playing
/// and come back with a tap (or the pointer, on the Mac).
struct VideoPlayerView: View {
    let playback: VideoPlayback
    /// The page's video, drawn as its frame until it's the one playing.
    let video: Video
    var isFullScreen = false
    /// Inline on the iPhone the page has no bar; its back button sits on the video.
    var onBack: (() -> Void)?

    @State private var showsControls = true
    @State private var isScrubbing = false
    /// Bumped by every touch of the controls, so they stay while they're being used.
    @State private var activity = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThis: Bool { playback.current?.id == video.id }
    private var hasPicture: Bool { isThis && playback.player.currentItem != nil }

    var body: some View {
        ZStack {
            Color.black
            if hasPicture {
                VideoSurface(player: playback.player, drivesPictureInPicture: isFullScreen || !playback.isFullScreen,
                             attach: playback.attach)
            } else {
                VideoThumbnail(video: video, cornerRadius: 0, width: 800)
            }
            if isThis, let error = playback.error {
                errorView(error)
            } else {
                controls
            }
        }
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .task(id: HideKey(activity: activity, playing: playback.isPlaying, scrubbing: isScrubbing)) {
            // Fade once the video has played a few seconds untouched; a paused video keeps them.
            guard playback.isPlaying, !isScrubbing, showsControls else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsControls = false }
        }
        .onChange(of: playback.isPlaying) { _, playing in if !playing { reveal() } }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            // A dim behind the controls so white reads on any frame.
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, isFullScreen ? 24 : 10)
            .padding(.vertical, isFullScreen ? 18 : 8)
            centre
        }
        .foregroundStyle(.white)
        .opacity(showsControls || !hasPicture ? 1 : 0)
        .allowsHitTesting(showsControls || !hasPicture)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showsControls)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if isFullScreen {
                ControlButton(systemImage: "xmark", label: "Exit Full Screen") { playback.isFullScreen = false }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.current?.title ?? video.title).font(.headline).lineLimit(1)
                    if let channel = (playback.current ?? video).channel?.name {
                        Text(channel).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .padding(.leading, 4)
            } else if let onBack {
                ControlButton(systemImage: "chevron.backward", label: "Back", action: onBack)
            }
            Spacer(minLength: 0)
            if hasPicture {
                RoutePicker()
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("AirPlay")
                if playback.canPictureInPicture {
                    ControlButton(systemImage: playback.isInPictureInPicture ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
                        poke()
                        playback.togglePictureInPicture()
                    }
                }
                VideoSettingsMenu(playback: playback) { poke() }
            }
        }
    }

    @ViewBuilder
    private var centre: some View {
        if isThis, playback.isLoading || (playback.isBuffering && !isScrubbing) {
            ProgressView().controlSize(.large).tint(.white)
        } else if hasPicture {
            HStack(spacing: isFullScreen ? 56 : 36) {
                if !playback.isLive {
                    ControlButton(systemImage: "gobackward.10", label: "Back 10 Seconds", size: 44) {
                        poke()
                        playback.skip(by: -10)
                    }
                }
                ControlButton(systemImage: playback.isPlaying ? "pause.fill" : "play.fill", label: playback.isPlaying ? "Pause" : "Play",
                              size: isFullScreen ? 72 : 60) {
                    poke()
                    playback.togglePlay()
                }
                .contentTransition(.symbolEffect(.replace))
                if !playback.isLive {
                    ControlButton(systemImage: "goforward.10", label: "Forward 10 Seconds", size: 44) {
                        poke()
                        playback.skip(by: 10)
                    }
                }
            }
            .opacity(showsControls ? 1 : 0)
        } else if !isThis {
            // Another video is on: this page's starts with a tap.
            ControlButton(systemImage: "play.fill", label: "Play", size: 64) { playback.play(video) }
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if hasPicture {
                if playback.isLive {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red, in: .capsule)
                    Spacer(minLength: 0)
                } else {
                    VideoScrubber(time: playback.time, duration: playback.duration, isScrubbing: $isScrubbing) { playback.seek(to: $0) }
                }
                ControlButton(systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              label: isFullScreen ? "Exit Full Screen" : "Full Screen") {
                    playback.isFullScreen.toggle()
                }
                .padding(.bottom, playback.isLive ? 0 : 18)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Play This Video", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { playback.retry() }.buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            if let onBack, !isFullScreen {
                ControlButton(systemImage: "chevron.backward", label: "Back", action: onBack).padding(10)
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.25)) { showsControls.toggle() }
        activity += 1
    }

    private func reveal() {
        if !showsControls { withAnimation(.easeOut(duration: 0.2)) { showsControls = true } }
        activity += 1
    }

    /// A control was used: keep them up a while longer.
    private func poke() {
        activity += 1
    }

    private struct HideKey: Equatable {
        let activity: Int
        let playing: Bool
        let scrubbing: Bool
    }
}

/// A round glass control over the video.
private struct ControlButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Quality, speed and captions, as submenus that show what's chosen.
private struct VideoSettingsMenu: View {
    let playback: VideoPlayback
    let touched: () -> Void

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { playback.quality }, set: { playback.setQuality($0) })) {
                Text("Auto").tag(0)
                ForEach(playback.qualities, id: \.self) { lines in
                    Text(Self.qualityName(lines)).tag(lines)
                }
            } label: {
                Label("Quality", systemImage: "dial.medium")
                Text(playback.quality == 0 ? "Auto" : Self.qualityName(playback.quality))
            }
            .pickerStyle(.menu)
            .disabled(playback.qualities.isEmpty)

            Picker(selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) })) {
                ForEach(VideoPlayback.speeds, id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : Self.speedName(rate)).tag(rate)
                }
            } label: {
                Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent")
                Text(playback.speed == 1 ? "Normal" : Self.speedName(playback.speed))
            }
            .pickerStyle(.menu)

            if !playback.captions.isEmpty {
                Picker(selection: Binding(get: { playback.caption }, set: { playback.setCaption($0) })) {
                    Text("Off").tag(AVMediaSelectionOption?.none)
                    ForEach(playback.captions, id: \.self) { option in
                        Text(option.displayName).tag(Optional(option))
                    }
                } label: {
                    Label("Captions", systemImage: "captions.bubble")
                    Text(playback.caption?.displayName ?? "Off")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: playback.caption == nil ? "gearshape.fill" : "captions.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .simultaneousGesture(TapGesture().onEnded(touched))
        .accessibilityLabel("Video Settings")
    }

    static func qualityName(_ lines: Int) -> String {
        switch lines {
        case 2160...: "4K"
        case 1440...: "1440p"
        default: "\(lines)p"
        }
    }

    static func speedName(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// Where the video is: drag anywhere on it to move through, the bar thickening under the finger;
/// the time moves with it and the video jumps when it's let go.
private struct VideoScrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    @Binding var isScrubbing: Bool
    let seek: (TimeInterval) -> Void
    @State private var dragged: Double?

    var body: some View {
        let fraction = dragged ?? (duration > 0 ? min(1, time / duration) : 0)
        let shown = duration * fraction
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: max(0, geometry.size.width * fraction))
                }
                .frame(height: dragged == nil ? 4 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Follows the finger with no animation; only the thickening animates.
                            if dragged == nil { withAnimation(.snappy(duration: 0.15)) { isScrubbing = true } }
                            dragged = min(1, max(0, value.location.x / max(geometry.size.width, 1)))
                        }
                        .onEnded { _ in
                            if let dragged { seek(duration * dragged) }
                            withAnimation(.snappy(duration: 0.15)) {
                                dragged = nil
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 22)
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(0, duration - shown)))
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.format(shown)) of \(Self.format(duration))")
        .accessibilityAdjustableAction { direction in
            seek(time + (direction == .increment ? 10 : -10))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let value = Duration.seconds(max(0, seconds.isFinite ? seconds : 0))
        return value.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The picture: an AVPlayerLayer. The surface in front drives picture in picture, so it can
/// start from full screen as from the page.
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let drivesPictureInPicture: Bool
    let attach: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if drivesPictureInPicture { attach(view.playerLayer) }
    }
}

private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The system's AirPlay button.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Full screen

/// The player filling the screen; on the iPhone a landscape video turns the screen with it.
struct FullScreenVideoView: View {
    let playback: VideoPlayback
    let video: Video

    var body: some View {
        VideoPlayerView(playback: playback, video: playback.current ?? video, isFullScreen: true)
            .ignoresSafeArea()
            .background(.black)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear {
                let size = playback.presentationSize
                Orientation.allow(.allButUpsideDown, prefer: size.height > size.width ? .portrait : .landscapeRight)
                // Its own claim on turning: the page under a cover counts as gone and lets go of its.
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            .onDisappear {
                Orientation.allow(.portrait, prefer: .portrait)
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            // Upright again with a landscape video: back to the page, the way it came.
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let size = playback.presentationSize
                if UIDevice.current.orientation == .portrait, size.width > size.height { playback.isFullScreen = false }
            }
    }
}

/// The iPhone is portrait everywhere but a full-screen video; the app delegate answers with this.
@MainActor
enum Orientation {
    static var allowed: UIInterfaceOrientationMask = .portrait

    static func allow(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        allowed = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { _ in }
    }
}

final class KodaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? Orientation.allowed : .all
    }
}

// MARK: - Swipe back without a bar

/// The watch page hides its bar (the back button is on the video), which also turns off the
/// edge swipe back; this turns it on again for that page, never at the root of a stack.
struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var previous: (any UIGestureRecognizerDelegate)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            if gesture.delegate !== self { previous = gesture.delegate }
            gesture.delegate = self
            gesture.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let gesture = navigationController?.interactivePopGestureRecognizer, gesture.delegate === self {
                gesture.delegate = previous
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

import AVFoundation
import AVKit
import KodaCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The video with Koda's own controls over it, the same inline and full screen: back (inline, on
/// the iPhone), AirPlay, picture in picture and a settings menu (quality, speed, captions) along
/// the top; back 10 s, play/pause and forward 10 s in the middle; a scrubber that follows the
/// finger, the times and full screen along the bottom. They fade after three seconds of playing
/// and come back with a tap (or the pointer, on the Mac).
///
/// Gestures, as Koda for Android has them: double-tap a side to skip 10 s (keep tapping to skip
/// further), touch and hold for 2× (slide sideways for other speeds), swipe up for full screen
/// and down to leave it; inline on the iPhone a swipe down hands the video to the mini player.
/// In full screen the left half sets the brightness and a pinch fills the screen. The Mac has
/// YouTube's keys instead, and a double-click for full screen.
struct VideoPlayerView: View {
    let playback: VideoPlayback
    /// The page's video, drawn as its frame until it's the one playing.
    let video: Video
    var isFullScreen = false
    /// Inline on the iPhone the page has no bar; its back button sits on the video.
    var onBack: (() -> Void)?
    /// A swipe down the inline video: the page goes and the video carries on in the mini player.
    var onMinimize: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var showsControls = true
    @State private var isScrubbing = false
    /// Bumped by every touch of the controls, so they stay while they're being used.
    @State private var activity = 0
    @State private var size: CGSize = .zero
    /// The double-tap skip being shown: which side, how far in all, and a pulse per tap.
    @State private var skipping: Skipping?
    @State private var skipTaps = 0
    @State private var isBoosting = false
    @State private var boostEnded = Date.distantPast
    /// What a vertical drag is doing, decided by where and which way it starts.
    @State private var drag: DragKind?
    /// How far the inline video follows a swipe down before it lets go.
    @State private var pullDown: CGFloat = 0
    @State private var brightness: CGFloat?
    @State private var brightnessAtStart: CGFloat = 0
    /// The screen's brightness before the video changed it, to give back on leaving.
    @State private var systemBrightness: CGFloat?
    @State private var fillsScreen = false
    @State private var note: String?
    @State private var showsResumed = false
    @State private var commits = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThis: Bool { playback.current?.id == video.id }
    private var hasPicture: Bool { isThis && playback.player.currentItem != nil }
    private var counting: Bool { isThis && playback.autoplayCountdown != nil && playback.upNext != nil }

    var body: some View {
        ZStack {
            Color.black
            if hasPicture {
                VideoSurface(player: playback.player, role: isFullScreen ? .fullScreen : .page,
                             fills: isFullScreen && fillsScreen, register: playback.register)
            } else {
                VideoThumbnail(video: video, cornerRadius: 0, width: 800, showsProgress: false)
            }
            gestureLayer
            if Platform.isMac, isThis, playback.isInPictureInPicture {
                // As the Mac's players show it: the picture is floating, so this one says so.
                PictureInPicturePlaceholder { playback.togglePictureInPicture() }
            }
            if isThis, let error = playback.error {
                errorView(error)
            } else if counting, let next = playback.upNext {
                UpNextCountdown(next: next, seconds: playback.autoplayCountdown ?? 0, isCompact: size.height < 230,
                                cancel: { playback.cancelAutoplay() }, play: { playback.playNext() })
                    .transition(.opacity)
            } else {
                if Platform.isMac { macControls } else { controls }
                feedback
            }
            if isThis, let skip = playback.sponsorSkip {
                SponsorSkipNote(skip: skip, undo: { playback.undoSponsorSkip() }, dismiss: { playback.dismissSponsorSkip() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(isFullScreen ? 28 : 14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .offset(y: pullDown)
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        // Only the player in front takes the keys (the page's stays under the full-screen one).
        .background { if Platform.isMac, isThis, isFullScreen == playback.isFullScreen { keyboardShortcuts } }
        .task(id: HideKey(activity: activity, playing: playback.isPlaying, scrubbing: isScrubbing)) {
            // Fade once the video has played a few seconds untouched; a paused video keeps them.
            guard playback.isPlaying, !isScrubbing, showsControls else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsControls = false }
        }
        .task(id: playback.resumedFrom) {
            guard isThis, playback.resumedFrom != nil else {
                showsResumed = false
                return
            }
            withAnimation(.smooth) { showsResumed = true }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.smooth) { showsResumed = false }
        }
        .task(id: note) {
            guard note != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.smooth) { note = nil }
        }
        .onChange(of: playback.isPlaying) { _, playing in if !playing { reveal() } }
        .onDisappear {
            playback.endBoost()
            if let systemBrightness { ScreenBrightness.set(systemBrightness) }
        }
        .sensoryFeedback(.selection, trigger: skipTaps)
        .sensoryFeedback(.impact(weight: .medium), trigger: commits)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: counting)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: playback.sponsorSkip)
    }

    // MARK: Mac controls

    /// The Mac's controls, the way its own players lay them out: everything in one glass bar along
    /// the foot of the picture (play, skips, the timeline, volume, captions, settings, AirPlay,
    /// picture in picture, theater and full screen), the title only in full screen, and nothing
    /// over the middle of the picture but a spinner, or Play for a video that isn't on yet.
    private var macControls: some View {
        ZStack {
            VStack(spacing: 0) {
                if isFullScreen {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130)
                }
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 150)
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 10) {
                if isFullScreen { macTitle }
                Spacer(minLength: 0)
                if showsResumed, let from = playback.resumedFrom {
                    ResumedNote(from: from) {
                        showsResumed = false
                        playback.seek(to: 0)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                macBar
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
            }
            .padding(isFullScreen ? 28 : 14)
            macCentre
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .opacity(controlsShown ? 1 : 0)
        .allowsHitTesting(controlsShown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showsControls)
    }

    private var macTitle: some View {
        HStack(spacing: 12) {
            ControlButton(systemImage: "xmark", label: "Exit Full Screen") { playback.isFullScreen = false }
            VStack(alignment: .leading, spacing: 1) {
                Text(playback.current?.title ?? video.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if let channel = (playback.current ?? video).channel?.name {
                    Text(channel).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var macCentre: some View {
        if isThis, playback.isLoading || (playback.isBuffering && !isScrubbing) {
            ProgressView().controlSize(.large).tint(.white)
        } else if !isThis {
            ControlButton(systemImage: "play.fill", label: "Play", size: 68) { playback.play(video) }
        } else if playback.hasEnded {
            ControlButton(systemImage: "arrow.counterclockwise", label: "Replay", size: 68) {
                poke()
                playback.togglePlay()
            }
        }
    }

    /// The bar. A narrow player drops the skips and theater (J, L and T still do them).
    private var macBar: some View {
        let compact = size.width < 620
        return HStack(spacing: compact ? 6 : 10) {
            MacBarButton(systemImage: playback.hasEnded ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill",
                         label: playback.isPlaying ? "Pause (Space)" : "Play (Space)", size: 18) {
                poke()
                if isThis { playback.togglePlay() } else { playback.play(video) }
            }
            .contentTransition(.symbolEffect(.replace))
            if hasPicture, !playback.isLive, !compact {
                MacBarButton(systemImage: "gobackward.10", label: "Back 10 Seconds (J)") {
                    poke()
                    playback.skip(by: -10)
                }
                MacBarButton(systemImage: "goforward.10", label: "Forward 10 Seconds (L)") {
                    poke()
                    playback.skip(by: 10)
                }
            }
            if hasPicture, playback.isLive {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: .capsule)
                Spacer(minLength: 0)
            } else if hasPicture {
                MacTimeline(playback: playback, isScrubbing: $isScrubbing)
                    .padding(.horizontal, 4)
            } else {
                Spacer(minLength: 0)
            }
            MacVolume(playback: playback)
            if hasPicture {
                if !playback.captions.isEmpty { MacCaptionsMenu(playback: playback) }
                MacVideoSettingsMenu(playback: playback)
                RoutePicker()
                    .frame(width: 17, height: 17)
                    .frame(width: 30, height: 30)
                    .help("AirPlay")
                    .accessibilityLabel("AirPlay")
                if playback.canPictureInPicture {
                    MacBarButton(systemImage: playback.isInPictureInPicture ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
                        poke()
                        playback.togglePictureInPicture()
                    }
                }
            }
            if !isFullScreen, !compact {
                MacBarButton(systemImage: app.settings.videoTheater ? "rectangle.inset.filled" : "rectangle.ratio.16.to.9",
                             label: app.settings.videoTheater ? "Default View (T)" : "Theater Mode (T)") {
                    poke()
                    toggleTheater()
                }
            }
            MacBarButton(systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         label: isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)") {
                playback.isFullScreen.toggle()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .glassEffect(.regular, in: .capsule)
        // Clicks between the buttons are the bar's, not the picture's (which would pause).
        .contentShape(.capsule)
        .onTapGesture {}
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
        .opacity(controlsShown ? 1 : 0)
        .allowsHitTesting(controlsShown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showsControls)
    }

    /// Up unless they've faded, or a gesture is drawing its own feedback over the picture.
    private var controlsShown: Bool {
        guard hasPicture else { return true }
        return showsControls && !isBoosting && skipping == nil && drag != .brightness
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if isFullScreen {
                ControlButton(systemImage: "xmark", label: "Exit Full Screen") { playback.isFullScreen = false }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.current?.title ?? video.title).font(.scaled(.headline)).lineLimit(1)
                    if let channel = (playback.current ?? video).channel?.name {
                        Text(channel).font(.scaled(.caption)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .padding(.leading, 4)
            } else if let onBack {
                ControlButton(systemImage: "chevron.backward", label: "Back", action: onBack)
            }
            Spacer(minLength: 0)
            if hasPicture {
                RoutePicker()
                    #if os(macOS)
                    // AppKit's route button fills its view; the symbol keeps the others' size.
                    .frame(width: 18, height: 18)
                    #endif
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
                if Platform.isMac, !isFullScreen {
                    ControlButton(systemImage: app.settings.videoTheater ? "rectangle.inset.filled" : "rectangle.ratio.16.to.9",
                                  label: app.settings.videoTheater ? "Default View" : "Theater Mode") {
                        poke()
                        toggleTheater()
                    }
                    .help(app.settings.videoTheater ? "Default View (T)" : "Theater Mode (T)")
                }
            }
        }
    }

    private func toggleTheater() {
        withAnimation(.smooth(duration: 0.3)) { app.settings.videoTheater.toggle() }
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
                ControlButton(systemImage: playback.hasEnded ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill",
                              label: playback.hasEnded ? "Replay" : playback.isPlaying ? "Pause" : "Play",
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
        } else if !isThis {
            // Another video is on: this page's starts with a tap.
            ControlButton(systemImage: "play.fill", label: "Play", size: 64) { playback.play(video) }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsResumed, let from = playback.resumedFrom {
                ResumedNote(from: from) {
                    showsResumed = false
                    playback.seek(to: 0)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 12) {
                if hasPicture {
                    if playback.isLive {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                            .font(.scaled(.caption).weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red, in: .capsule)
                        Spacer(minLength: 0)
                    } else {
                        LiveScrubber(playback: playback, isScrubbing: $isScrubbing)
                    }
                    ControlButton(systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  label: isFullScreen ? "Exit Full Screen" : "Full Screen") {
                        playback.isFullScreen.toggle()
                    }
                    .padding(.bottom, playback.isLive ? 0 : 18)
                }
            }
        }
    }

    /// What the gestures draw over the picture: the skip, the speed, the brightness, the zoom.
    private var feedback: some View {
        ZStack {
            if let skipping {
                SkipBadge(skipping: skipping, isFullScreen: isFullScreen, width: size.width * 0.38)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipping.forward ? .trailing : .leading)
                    .transition(.opacity)
            }
            if isBoosting, let rate = playback.boost {
                Label {
                    Text("\(VideoSettingsMenu.speedName(rate))").monospacedDigit().contentTransition(.numericText(value: Double(rate)))
                } icon: {
                    Image(systemName: "forward.fill")
                }
                .font(.scaled(.subheadline).weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, isFullScreen ? 24 : 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if drag == .brightness, let brightness {
                LevelIndicator(value: brightness, systemImage: "sun.max.fill", label: "Brightness")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
            if let note {
                Text(note)
                    .font(.scaled(.subheadline).weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isBoosting)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: skipping?.forward)
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

    // MARK: Gestures

    /// The picture's own gestures, on a layer of their own under the controls rather than on the
    /// view holding them: a double tap on a parent makes SwiftUI hold back its buttons' taps
    /// (the controls stopped answering on the Mac). Here a click on a button is the button's, and
    /// one anywhere else (the controls let it through) is the picture's.
    private var gestureLayer: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(taps)
            .simultaneousGesture(hold, isEnabled: hasPicture && !Platform.isMac && app.settings.holdsToSpeedUp)
            .simultaneousGesture(swipe, isEnabled: !Platform.isMac)
            .simultaneousGesture(pinch, isEnabled: isFullScreen && hasPicture && !Platform.isMac)
    }

    /// One tap shows or hides the controls; two skip (iPhone) or go full screen (Mac). While a
    /// skip is showing, single taps on that side keep skipping, as on YouTube.
    private var taps: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if Platform.isMac {
                    playback.isFullScreen.toggle()
                } else {
                    skip(at: value.location)
                }
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                // The lift that ends a hold isn't a tap.
                guard Date().timeIntervalSince(boostEnded) > 0.3 else { return }
                if let skipping, hasPicture, side(of: value.location) == (skipping.forward ? 1 : -1) {
                    skip(at: value.location)
                } else if Platform.isMac, hasPicture {
                    // A click on the picture plays or pauses, as the Mac's players do.
                    playback.togglePlay()
                    reveal()
                } else {
                    toggleControls()
                }
            })
    }

    /// -1 for the left third, 1 for the right, 0 between.
    private func side(of point: CGPoint) -> Int {
        guard size.width > 0 else { return 0 }
        let x = point.x / size.width
        return x < 0.4 ? -1 : x > 0.6 ? 1 : 0
    }

    private func skip(at point: CGPoint) {
        guard hasPicture, !playback.isLive else { return }
        let direction = side(of: point)
        guard direction != 0 else {
            // Two taps in the middle play or pause, as YouTube's do.
            playback.togglePlay()
            return
        }
        let forward = direction > 0
        let seconds = skipping?.forward == forward ? (skipping?.seconds ?? 0) + 10 : 10
        withAnimation(.smooth(duration: 0.2)) { skipping = Skipping(forward: forward, seconds: seconds, pulse: skipTaps + 1) }
        skipTaps += 1
        playback.skip(by: forward ? 10 : -10)
        let pulse = skipTaps
        Task {
            try? await Task.sleep(for: .seconds(0.75))
            if skipTaps == pulse { withAnimation(.smooth(duration: 0.25)) { skipping = nil } }
        }
    }

    /// Hold for 2×; slide the held finger right or left for faster or slower, in quarter steps.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let dragged) = value else { return }
                if !isBoosting {
                    guard playback.isPlaying, !playback.isLive else { return }
                    isBoosting = true
                    commits += 1
                    playback.startBoost(2)
                }
                if let dragged {
                    let steps = (dragged.translation.width / 36).rounded(.towardZero)
                    let rate = 2 + Float(steps) * 0.25
                    if rate != playback.boost { playback.setBoost(rate) }
                }
            }
            .onEnded { _ in endBoost() }
    }

    private func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        boostEnded = Date()
        playback.endBoost()
    }

    private enum DragKind {
        case enterFullScreen, minimize, exitFullScreen, brightness
    }

    /// Up for full screen, down to leave it (or, inline, to the mini player); in full screen the
    /// left half's lane is the brightness.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !isBoosting, !isScrubbing else { return }
                let dx = value.translation.width, dy = value.translation.height
                if drag == nil {
                    // Sideways is the scrubber's; only a clearly vertical drag is ours.
                    guard abs(dy) > abs(dx) * 1.4 else { return }
                    drag = kind(start: value.startLocation, down: dy > 0)
                    if drag == .brightness {
                        let current = ScreenBrightness.current ?? 0.5
                        if systemBrightness == nil { systemBrightness = current }
                        brightnessAtStart = current
                    }
                }
                switch drag {
                case .brightness:
                    // The lane's full height takes it from dark to bright.
                    let level = min(1, max(0, brightnessAtStart - dy / max(size.height * 0.8, 1)))
                    brightness = level
                    ScreenBrightness.set(level)
                case .minimize:
                    // Follows the finger, with resistance, so it's clear what letting go will do.
                    pullDown = max(0, dy) * 0.55
                case .enterFullScreen:
                    if dy < -60 {
                        drag = nil
                        commits += 1
                        playback.isFullScreen = true
                    }
                case .exitFullScreen:
                    if dy > 70 {
                        drag = nil
                        commits += 1
                        playback.isFullScreen = false
                    }
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard drag == .minimize else { return }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 260, let onMinimize {
                    commits += 1
                    onMinimize()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pullDown = 0 }
                }
            }
    }

    private func kind(start: CGPoint, down: Bool) -> DragKind? {
        if isFullScreen {
            // Clear of the top edge, where a pull is the system's.
            if start.x < size.width / 2, start.y > size.height * 0.15, app.settings.swipesForBrightness, hasPicture { return .brightness }
            return down ? .exitFullScreen : nil
        }
        if down { return onMinimize == nil ? nil : .minimize }
        return hasPicture ? .enterFullScreen : nil
    }

    /// Pinch open to fill the screen (cropping the edges), closed to see the whole picture.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                let fills = value.magnification > 1.12 ? true : value.magnification < 0.9 ? false : fillsScreen
                guard fills != fillsScreen else { return }
                withAnimation(.smooth) {
                    fillsScreen = fills
                    note = fills ? "Zoomed to Fill" : "Original"
                }
                commits += 1
            }
    }

    /// YouTube's keys on the Mac: Space and K play/pause, J and L skip 10 s, ← and → skip 5,
    /// F full screen (Esc leaves it), T theater mode, M mute.
    private var keyboardShortcuts: some View {
        Group {
            Button("Play/Pause") { playback.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Play/Pause") { playback.togglePlay() }.keyboardShortcut("k", modifiers: [])
            Button("Back 10 Seconds") { playback.skip(by: -10) }.keyboardShortcut("j", modifiers: [])
            Button("Forward 10 Seconds") { playback.skip(by: 10) }.keyboardShortcut("l", modifiers: [])
            Button("Back 5 Seconds") { playback.skip(by: -5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 5 Seconds") { playback.skip(by: 5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Full Screen") { playback.isFullScreen.toggle() }.keyboardShortcut("f", modifiers: [])
            if isFullScreen {
                Button("Exit Full Screen") { playback.isFullScreen = false }.keyboardShortcut(.escape, modifiers: [])
            }
            Button("Theater Mode") { toggleTheater() }.keyboardShortcut("t", modifiers: [])
            Button("Mute") {
                playback.isMuted.toggle()
                note = playback.isMuted ? "Muted" : "Sound On"
            }
            .keyboardShortcut("m", modifiers: [])
            // YouTube's own: 0–9 jump to that tenth, , and . step a frame while paused, < and >
            // change the speed, C turns subtitles on or off.
            ForEach(0..<10, id: \.self) { tenth in
                Button("Jump to \(tenth * 10)%") {
                    guard playback.duration > 0, !playback.isLive else { return }
                    playback.seek(to: playback.duration * Double(tenth) / 10)
                    reveal()
                }
                .keyboardShortcut(KeyEquivalent(Character(String(tenth))), modifiers: [])
            }
            Button("Previous Frame") { playback.step(by: -1) }.keyboardShortcut(",", modifiers: [])
            Button("Next Frame") { playback.step(by: 1) }.keyboardShortcut(".", modifiers: [])
            Button("Slower") {
                playback.stepSpeed(by: -1)
                note = playback.speed == 1 ? "Normal Speed" : VideoSettingsMenu.speedName(playback.speed)
            }
            .keyboardShortcut(",", modifiers: .shift)
            Button("Faster") {
                playback.stepSpeed(by: 1)
                note = playback.speed == 1 ? "Normal Speed" : VideoSettingsMenu.speedName(playback.speed)
            }
            .keyboardShortcut(".", modifiers: .shift)
            Button("Subtitles") {
                guard !playback.captions.isEmpty else {
                    note = "No Subtitles"
                    return
                }
                playback.toggleCaptions()
                note = playback.caption.map { "Subtitles: \($0.displayName)" } ?? "Subtitles Off"
            }
            .keyboardShortcut("c", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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

/// A double-tap skip in progress.
struct Skipping: Equatable {
    var forward: Bool
    /// The seconds skipped by this run of taps.
    var seconds: Int
    var pulse: Int
}

/// The skip, drawn over the side that was tapped: an arc of light from that edge with the
/// arrows and how far it has gone, as YouTube draws it.
private struct SkipBadge: View {
    let skipping: Skipping
    let isFullScreen: Bool
    let width: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.white.opacity(0.14))
                .scaleEffect(x: 1.5, y: 1.4, anchor: skipping.forward ? .leading : .trailing)
                .offset(x: skipping.forward ? 70 : -70)
            VStack(spacing: 6) {
                Image(systemName: skipping.forward ? "forward.fill" : "backward.fill")
                    .font(.scaledSystem(size: isFullScreen ? 26 : 20, weight: .semibold))
                    .symbolEffect(.bounce, value: skipping.pulse)
                Text("\(skipping.seconds) seconds")
                    .font(.scaled(.caption).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(skipping.seconds)))
            }
            .offset(x: skipping.forward ? 18 : -18)
        }
        .frame(maxHeight: .infinity)
        .frame(width: max(width, 1))
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(skipping.forward ? "Forward \(skipping.seconds) seconds" : "Back \(skipping.seconds) seconds")
    }
}

/// A level being set by a swipe: a slim glass bar filling from the bottom, its symbol under it.
private struct LevelIndicator: View {
    let value: CGFloat
    let systemImage: String
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 6, height: 120)
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white).frame(width: 6, height: 120 * value)
                }
            Image(systemName: systemImage).font(.scaled(.subheadline).weight(.semibold))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// "Resumed at 4:12", with the way back to the start.
private struct ResumedNote: View {
    let from: TimeInterval
    let startOver: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Resumed at \(VideoScrubber.format(from))")
                .font(.scaled(.footnote).weight(.medium))
                .monospacedDigit()
            Button("Start Over", action: startOver)
                .font(.scaled(.footnote).weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .underline()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The end of a video with Up Next about to start: what it is, the seconds left, and both ways
/// out. Compact inline on the iPhone, where the frame is short.
private struct UpNextCountdown: View {
    let next: Video
    let seconds: Int
    let isCompact: Bool
    let cancel: () -> Void
    let play: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            HStack(alignment: .center, spacing: 14) {
                if !isCompact {
                    VideoThumbnail(video: next, cornerRadius: 10, width: 180).frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up Next in \(seconds)")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(next.title)
                        .font(isCompact ? .scaled(.subheadline).weight(.semibold) : .scaled(.headline))
                        .lineLimit(2)
                    if let channel = next.channel?.name {
                        Text(channel).font(.scaled(.caption)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Button("Cancel", action: cancel).buttonStyle(.glass)
                        Button("Play Now", action: play).buttonStyle(.glassProminent)
                    }
                    .controlSize(isCompact ? .small : .regular)
                    .padding(.top, 6)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .foregroundStyle(.white)
        }
        .animation(.smooth, value: seconds)
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
                .font(.scaledSystem(size: size * 0.42, weight: .semibold))
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
                // The default may be one this video doesn't come in; it still shows as chosen.
                if playback.quality != 0, !playback.qualities.contains(playback.quality) {
                    Text(Self.qualityName(playback.quality)).tag(playback.quality)
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
                .font(.scaledSystem(size: 15, weight: .semibold))
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
        VideoQualityName.short(lines)
    }

    static func speedName(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// Where the video is: drag anywhere on it to move through, the bar thickening under the finger;
/// the time moves with it and the video jumps when it's let go.
struct VideoScrubber: View {
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
            .font(.scaled(.caption2).weight(.medium).monospacedDigit())
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

/// The picture: an AVPlayerLayer, registered with the player under its role so picture in
/// picture can float whichever is in front.
struct VideoSurface {
    let player: AVPlayer
    let role: VideoPlayback.SurfaceRole
    /// Cropped to fill the frame rather than fitted inside it.
    var fills = false
    let register: (AVPlayerLayer, VideoPlayback.SurfaceRole) -> Void

    private func make() -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return view
    }

    private func update(_ view: PlayerLayerView) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            view.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
        register(view.playerLayer, role)
    }
}

#if os(macOS)
extension VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerLayerView { make() }
    func updateNSView(_ view: PlayerLayerView, context: Context) { update(view) }
}

/// A view whose layer is an AVPlayerLayer (layer-hosting, as AppKit has it).
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The system's AirPlay button.
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(.systemBlue, for: .active)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// A Mac has no screen brightness an app may set.
enum ScreenBrightness {
    static var current: CGFloat? { nil }
    static func set(_ level: CGFloat?) {}
}
#else
extension VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerView { make() }
    func updateUIView(_ view: PlayerLayerView, context: Context) { update(view) }
}

final class PlayerLayerView: UIView {
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

/// The brightness of the screen the app is on, for the full-screen brightness lane.
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.screen
    }

    static var current: CGFloat? { screen?.brightness }

    static func set(_ level: CGFloat?) {
        if let level { screen?.brightness = level }
    }
}
#endif

// MARK: - Full screen

/// The player filling the screen; on the iPhone a landscape video turns the screen with it. The
/// iPhone presents it as a cover, the Mac in a window of its own (MacVideoWindow).
struct FullScreenVideoView: View {
    let playback: VideoPlayback
    let video: Video

    var body: some View {
        VideoPlayerView(playback: playback, video: playback.current ?? video, isFullScreen: true)
            .ignoresSafeArea()
            .background(.black)
            #if os(iOS)
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
            #endif
    }
}

#if os(iOS)
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
#endif

/// "Skipped Sponsor", with Undo, for a few seconds after SponsorBlock skips a part.
private struct SponsorSkipNote: View {
    let skip: VideoPlayback.SponsorSkip
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Skipped \(skip.title)", systemImage: "forward.end.fill")
                .font(.system(size: 13, weight: .semibold))
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .task(id: skip.id) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { dismiss() }
        }
    }
}

/// Where the picture was, while it floats in picture in picture.
private struct PictureInPicturePlaceholder: View {
    let bringBack: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "pip").font(.system(size: 44, weight: .light))
                Text("This video is playing in Picture in Picture.")
                    .font(.system(size: 13, weight: .medium))
                Button("Return to Window", action: bringBack)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .foregroundStyle(.white.opacity(0.75))
            .environment(\.colorScheme, .dark)
        }
    }
}

/// The playing time as its own view: the timeline is the only part of the controls that changes
/// four times a second. Reading it in the player's body redrew the whole of it each time, and
/// an open menu in it (quality, speed) lost its submenus while the video played.
private struct LiveScrubber: View {
    let playback: VideoPlayback
    @Binding var isScrubbing: Bool

    var body: some View {
        VideoScrubber(time: playback.time, duration: playback.duration, isScrubbing: $isScrubbing) { playback.seek(to: $0) }
    }
}

/// A symbol button in the Mac's control bar: no glass of its own (the bar is the glass), lit
/// under the pointer, with its shortcut in the tooltip.
private struct MacBarButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(BarButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The Mac's timeline: the time played, the line, the time left. The line breaks at each
/// chapter and marks SponsorBlock's parts; under the pointer it thickens and shows, above it,
/// the frame there (YouTube's storyboard), the chapter's name and the time. A click or drag goes there.
private struct MacTimeline: View {
    let playback: VideoPlayback
    @Binding var isScrubbing: Bool
    @State private var dragged: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        let duration = playback.duration
        let fraction = dragged ?? (duration > 0 ? min(1, playback.time / duration) : 0)
        let shown = duration * fraction
        HStack(spacing: 10) {
            Text(VideoScrubber.format(shown))
                .frame(minWidth: 36, alignment: .trailing)
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let thick = hoverX != nil || dragged != nil
                let starts = duration > 0 ? playback.chapters.map { CGFloat($0.start / duration) } : []
                let track = ChapterTrack(starts: starts)
                ZStack(alignment: .leading) {
                    track.fill(.white.opacity(0.28))
                    // SponsorBlock's parts, where they are on the line.
                    if duration > 0 {
                        ForEach(playback.sponsorSegments, id: \.id) { segment in
                            Rectangle()
                                .fill(.green.opacity(0.85))
                                .frame(width: max(2, width * CGFloat((segment.end - segment.start) / duration)))
                                .offset(x: width * CGFloat(segment.start / duration))
                        }
                        .mask(track)
                    }
                    Rectangle().fill(.white)
                        .frame(width: max(0, width * fraction))
                        .mask(track)
                }
                .frame(height: thick ? 7 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .overlay(alignment: .bottomLeading) {
                    if let hoverX, dragged == nil, duration > 0 {
                        let seconds = duration * Double(min(1, max(0, hoverX / width)))
                        // Centred over the pointer (kept within the line's ends), floating clear
                        // above the control bar.
                        TimelinePreview(playback: playback, seconds: seconds)
                            .fixedSize()
                            .alignmentGuide(.leading) { $0.width / 2 - min(max(hoverX, $0.width / 2), width - $0.width / 2) }
                            .alignmentGuide(.bottom) { $0[.bottom] + 34 }
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragged == nil { isScrubbing = true }
                            dragged = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { _ in
                            if let dragged { playback.seek(to: duration * dragged) }
                            dragged = nil
                            isScrubbing = false
                        })
                .animation(.snappy(duration: 0.15), value: thick)
            }
            .frame(height: 24)
            Text("-" + VideoScrubber.format(max(0, duration - shown)))
                .frame(minWidth: 40, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(VideoScrubber.format(shown)) of \(VideoScrubber.format(duration))")
        .accessibilityAdjustableAction { direction in
            playback.seek(to: playback.time + (direction == .increment ? 10 : -10))
        }
    }
}

/// The timeline's line, broken where each chapter after the first starts.
private nonisolated struct ChapterTrack: Shape {
    /// Where chapters start, as fractions of the video.
    let starts: [CGFloat]

    func path(in rect: CGRect) -> Path {
        let gap: CGFloat = 2
        let edges = ([0] + starts.filter { $0 > 0.001 && $0 < 0.999 } + [1]).sorted()
        var path = Path()
        for (from, to) in zip(edges, edges.dropFirst()) {
            let start = rect.minX + rect.width * from + (from > 0 ? gap / 2 : 0)
            let end = rect.minX + rect.width * to - (to < 1 ? gap / 2 : 0)
            guard end > start else { continue }
            path.addRoundedRect(in: CGRect(x: start, y: rect.minY, width: end - start, height: rect.height),
                                cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        }
        return path
    }
}

/// Over the timeline under the pointer: the frame at that time (when YouTube has a storyboard
/// for the video), the chapter's name and the time.
private struct TimelinePreview: View {
    let playback: VideoPlayback
    let seconds: TimeInterval

    var body: some View {
        VStack(spacing: 6) {
            if let frame = playback.storyboard?.frame(at: seconds, duration: playback.duration) {
                StoryboardFrame(frame: frame)
                    .frame(width: 176, height: 99)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
            }
            if let chapter = VideoChapter.current(in: playback.chapters, at: seconds) {
                Text(chapter.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 176)
            }
            Text(VideoScrubber.format(seconds))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// One frame cut from a storyboard sheet. Sheets are kept as they load, so moving along the
/// timeline reuses them (25 frames to a sheet).
private struct StoryboardFrame: View {
    let frame: VideoStoryboard.Frame
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: frame) { image = await StoryboardSheets.shared.frame(frame) }
    }
}

@MainActor
private final class StoryboardSheets {
    static let shared = StoryboardSheets()
    private var sheets: [URL: CGImage] = [:]

    func frame(_ frame: VideoStoryboard.Frame) async -> CGImage? {
        let sheet: CGImage
        if let cached = sheets[frame.sheet] {
            sheet = cached
        } else {
            // Asked for larger than any sheet, so it comes at its own size (thumbnails never upscale)
            // and frames are cut at their stated pixels; a last sheet can be shorter than the rest.
            guard let loaded = await ImagePipeline.shared.image(frame.sheet, pixels: 4096)?.cgImage else { return nil }
            if sheets.count > 24 { sheets.removeAll() }
            sheets[frame.sheet] = loaded
            sheet = loaded
        }
        let rect = frame.rect.intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        guard !rect.isEmpty else { return nil }
        return sheet.cropping(to: rect)
    }
}

/// The speaker: a click mutes, and under the pointer a slider slides out beside it, as the
/// Mac's players have it.
private struct MacVolume: View {
    @Bindable var playback: VideoPlayback
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 4) {
            MacBarButton(systemImage: symbol, label: playback.isMuted ? "Unmute (M)" : "Mute (M)") {
                playback.isMuted.toggle()
            }
            .contentTransition(.symbolEffect(.replace))
            if expanded {
                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.28))
                        Capsule().fill(.white).frame(width: width * CGFloat(playback.isMuted ? 0 : playback.volume))
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        playback.volume = Float(min(1, max(0, value.location.x / width)))
                        if playback.isMuted { playback.isMuted = false }
                    })
                }
                .frame(width: 76, height: 24)
                .padding(.trailing, 4)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onHover { over in withAnimation(.snappy(duration: 0.2)) { expanded = over } }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(Double(playback.isMuted ? 0 : playback.volume), format: .percent.precision(.fractionLength(0))))
    }

    private var symbol: String {
        if playback.isMuted || playback.volume == 0 { return "speaker.slash.fill" }
        return playback.volume < 0.34 ? "speaker.wave.1.fill" : playback.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Subtitles, as their own button the way the Mac's players have it: Off or a language.
private struct MacCaptionsMenu: View {
    let playback: VideoPlayback

    var body: some View {
        Menu {
            Picker("Subtitles", selection: Binding(get: { playback.caption }, set: { playback.setCaption($0) })) {
                Text("Off").tag(AVMediaSelectionOption?.none)
                ForEach(playback.captions, id: \.self) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: playback.caption == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles")
        .accessibilityLabel("Subtitles")
    }
}

/// Quality and Playback Speed, each a submenu showing what's chosen.
private struct MacVideoSettingsMenu: View {
    let playback: VideoPlayback

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { playback.quality }, set: { playback.setQuality($0) })) {
                Text("Auto").tag(0)
                ForEach(playback.qualities, id: \.self) { lines in
                    Text(VideoQualityName.short(lines)).tag(lines)
                }
                if playback.quality != 0, !playback.qualities.contains(playback.quality) {
                    Text(VideoQualityName.short(playback.quality)).tag(playback.quality)
                }
            } label: {
                Text("Quality")
                Text(playback.quality == 0 ? "Auto" : VideoQualityName.short(playback.quality))
            }
            .pickerStyle(.menu)
            .disabled(playback.qualities.isEmpty)
            Picker(selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) })) {
                ForEach(VideoPlayback.speeds, id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : VideoSettingsMenu.speedName(rate)).tag(rate)
                }
            } label: {
                Text("Playback Speed")
                Text(playback.speed == 1 ? "Normal" : VideoSettingsMenu.speedName(playback.speed))
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quality and Speed")
        .accessibilityLabel("Video Settings")
    }
}

/// What a quality is called: "1080p", "4K"; Settings adds what the tall ones are known as.
enum VideoQualityName {
    static func short(_ lines: Int) -> String {
        switch lines {
        case 0: "Auto"
        case 2160...: "4K"
        default: "\(lines)p"
        }
    }

    static func long(_ lines: Int) -> String {
        switch lines {
        case 0: "Auto"
        case 2160...: "4K (2160p)"
        case 1440: "1440p (2K)"
        case 1080: "1080p (Full HD)"
        case 720: "720p (HD)"
        default: "\(lines)p"
        }
    }
}

import KodaCore
import SwiftUI

/// Where Koda runs. The iPhone layout and the Mac's share their screens; only the shell
/// around them differs: a sidebar, a player bar and a menu bar on the Mac.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif
}

// MARK: - Player bar

/// The Mac's mini player: a floating glass bar under the page, always there once something
/// has played. The song on the left opens Now Playing; the transport and progress sit in
/// the middle, where the eye expects them; lyrics, queue and volume on the right.
struct MacPlayerBar: View {
    /// The song opens Now Playing; lyrics and the queue open beside the page instead.
    let openNowPlaying: () -> Void
    /// Where Now Playing zooms out of and back into.
    var zoom: Namespace.ID?
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var width: CGFloat = 900

    /// A narrow window: the transport gives up some width, and the volume keeps its speaker.
    private var isNarrow: Bool { width < 760 }
    /// The smallest windows: shuffle and repeat step out (the Controls menu keeps both), so the
    /// song's title still has room beside the transport.
    private var isCompact: Bool { width < 560 }

    var body: some View {
        HStack(spacing: isNarrow ? 10 : 16) {
            nowPlaying
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                transport
                BarProgress()
            }
            .frame(width: isCompact ? 180 : isNarrow ? 270 : 360)
            // Compact, the transport moves off centre to leave the title what's left.
            trailing
                .frame(maxWidth: isCompact ? nil : .infinity, alignment: .trailing)
        }
        // Measured on a flexible frame: the bar's own parts have fixed widths, and measuring
        // them would hold the bar at its old width.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, 12)
        .frame(height: 68)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var nowPlaying: some View {
        Button { openNowPlaying() } label: {
            HStack(spacing: 12) {
                // Concentric with the bar's corners, as the system's own nested shapes are.
                ArtworkView(artwork: player.current?.artwork, size: 46, cornerRadius: 12)
                    .modifier(ZoomSource(namespace: zoom))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "Not Playing")
                        .font(.callout.weight(.semibold))
                    Text(player.current?.artistLine ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .contentTransition(.opacity)
                if let mixing = player.mixing {
                    MixingBadge(mixing: mixing, compact: true)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .contentShape(.rect)
            .animation(.smooth(duration: 0.35), value: player.mixing)
        }
        .buttonStyle(BarButtonStyle(padding: 4))
        .disabled(player.current == nil)
        .help("Show Now Playing")
        .animation(.smooth(duration: 0.3), value: player.current?.id)
    }

    private var transport: some View {
        HStack(spacing: isNarrow ? 8 : 18) {
            if !isCompact {
                iconButton("shuffle", help: "Shuffle", isOn: player.isShuffled) { player.setShuffle(!player.isShuffled) }
            }
            iconButton("backward.fill", help: "Previous") { player.previous() }
            if app.settings.showsSkipButtons {
                let interval = app.settings.skipInterval
                iconButton(interval.backSymbol, help: "Back \(interval.rawValue) Seconds (⌥⌘←)") { player.skip(by: -interval.seconds) }
                    .disabled(player.phase != .ready)
            }
            PlayPauseButton(size: 18)
            if app.settings.showsSkipButtons {
                let interval = app.settings.skipInterval
                iconButton(interval.forwardSymbol, help: "Ahead \(interval.rawValue) Seconds (⌥⌘→)") { player.skip(by: interval.seconds) }
                    .disabled(player.phase != .ready)
            }
            iconButton("forward.fill", help: "Next") { player.next() }
            if !isCompact {
                iconButton(player.repeatMode == .one ? "repeat.1" : "repeat", help: "Repeat", isOn: player.repeatMode != .off) {
                    player.cycleRepeat()
                }
            }
        }
        .disabled(player.current == nil)
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            iconButton("quote.bubble", help: "Lyrics", isOn: app.sidePanel == .lyrics) { app.toggleLyricsOrQueue(.lyrics) }
                .disabled(player.current == nil)
            iconButton("list.bullet", help: "Up Next", isOn: app.sidePanel == .queue) { app.toggleLyricsOrQueue(.queue) }
                .disabled(player.current == nil)
            BarVolume(showsSlider: !isNarrow)
                .frame(width: isNarrow ? 22 : 110)
                .padding(.leading, isNarrow ? 0 : 6)
        }
    }

    private func iconButton(_ symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .frame(width: 28, height: 28)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A plain button that lights up under the pointer and dims on press, as toolbar buttons do.
struct BarButtonStyle: ButtonStyle {
    var padding: CGFloat = 0
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.06 : 0)))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// A thin progress line that thickens under the pointer; a click or drag puts the song there.
private struct BarProgress: View {
    @Environment(Player.self) private var player
    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(player.duration, 1)
            let fraction = dragFraction ?? min(1, player.position(at: context.date) / duration)
            HStack(spacing: 8) {
                Text(format(fraction * duration))
                    .frame(width: 36, alignment: .trailing)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule().fill(.primary.opacity(0.7))
                            .frame(width: max(0, width * fraction))
                    }
                    .shimmer(player.isBuffering)
                    .clipShape(.capsule)
                    .frame(height: hovering || dragFraction != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = min(1, max(0, $0.location.x / width)) }
                            .onEnded { _ in
                                if let dragFraction { player.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            })
                }
                .frame(height: 12)
                Text(format(duration))
                    .frame(width: 36, alignment: .leading)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .animation(.snappy(duration: 0.15), value: hovering)
        }
        .disabled(player.phase != .ready)
        .accessibilityElement()
        .accessibilityLabel("Position")
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Koda's own volume, drawn like the progress line; the speaker shows how loud it is.
private struct BarVolume: View {
    /// Off in a narrow window: the speaker alone, which still mutes, and ⌘↑ ⌘↓ still change it.
    var showsSlider = true
    @Environment(Player.self) private var player
    @State private var hovering = false

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 6) {
            Button {
                player.volume = player.volume > 0 ? 0 : 0.7
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(player.volume > 0 ? "Mute" : "Unmute")
            if showsSlider { slider }
        }
        .animation(.snappy(duration: 0.15), value: hovering)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(Double(player.volume), format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            player.volume = min(1, max(0, player.volume + (direction == .increment ? 0.1 : -0.1)))
        }
    }

    private var slider: some View {
        @Bindable var player = player
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary.opacity(0.7))
                    .frame(width: max(0, width * CGFloat(player.volume)))
            }
            .clipShape(.capsule)
            .frame(height: hovering ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                player.volume = Float(min(1, max(0, $0.location.x / width)))
            })
        }
        .frame(height: 12)
    }

    private var symbol: String {
        switch player.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

// MARK: - Menu bar

/// The Controls and Go menus, with the shortcuts Music uses where Koda has the same action.
struct KodaCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Controls") {
            let player = model.player
            let hasSong = player.current != nil
            Button(player.wantsToPlay ? "Pause" : "Play") { player.togglePlayPause(from: "the menu bar") }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!hasSong)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!hasSong)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!hasSong)
            let interval = model.settings.skipInterval
            Button("Skip Ahead \(interval.rawValue) Seconds") { player.skip(by: interval.seconds) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(player.phase != .ready)
            Button("Skip Back \(interval.rawValue) Seconds") { player.skip(by: -interval.seconds) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(player.phase != .ready)
            #if DEBUG
            // For hearing transitions without waiting out each song; Debug builds only.
            Button("Jump to Next Transition") { player.jumpToTransition() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(player.phase != .ready)
            #endif
            Divider()
            Button("Increase Volume") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) }))
                .disabled(!hasSong)
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            .disabled(!hasSong)
            Divider()
            Button(model.isNowPlayingPresented ? "Hide Now Playing" : "Show Now Playing") {
                model.isNowPlayingPresented.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!hasSong)
            Button("Lyrics") { model.toggleLyricsOrQueue(.lyrics) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!hasSong)
            Button("Queue") { model.toggleLyricsOrQueue(.queue) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!hasSong)
        }
        CommandMenu("Go") {
            Button("Home") { model.go(to: .home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Library") { model.go(to: .library) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Search") { model.go(to: .search) }
                .keyboardShortcut("f", modifiers: .command)
            if model.settings.videoModeEnabled {
                Divider()
                Button("Videos") { model.go(to: .videos) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Watch History") { model.go(to: .watched) }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.isProfilePresented = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        // One window is the whole app; a second would play over the first.
        CommandGroup(replacing: .newItem) {}
    }
}

/// Marks the view Now Playing zooms out of, when there is a namespace to mark it in.
private struct ZoomSource: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: "player", in: namespace) { $0.clipShape(.rect(cornerRadius: 12)) }
        } else {
            content
        }
    }
}

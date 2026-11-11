import KodaCore
import SwiftUI

/// Where Koda runs. The iPhone layout and the Mac's share their screens; only the shell
/// around them differs: a sidebar, a player bar and a menu bar on the Mac.
enum Platform {
    #if targetEnvironment(macCatalyst) || os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// The native Mac app rather than Catalyst, for the few places they differ in what they show.
    #if os(macOS)
    static let isNativeMac = true
    #else
    static let isNativeMac = false
    #endif
}

// MARK: - Player bar

/// The Mac's mini player, laid out as Music's: a glass capsule floating over the foot of the
/// page, centred and no wider than it needs. The transport on the left; in the middle a panel
/// with the cover, the song and its progress (the cover or the song opens Now Playing); lyrics,
/// Up Next and volume on the right.
struct MacPlayerBar: View {
    /// The song opens Now Playing; lyrics and the queue open beside the page instead.
    let openNowPlaying: () -> Void
    /// Where Now Playing zooms out of and back into.
    var zoom: Namespace.ID?
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var width: CGFloat = 900

    /// A narrow bar: the transport tightens, and the volume keeps only its speaker.
    private var isNarrow: Bool { width < 700 }
    /// The smallest: shuffle and repeat step out (the Controls menu keeps both), so the song
    /// still has room in the middle.
    private var isCompact: Bool { width < 540 }

    var body: some View {
        HStack(spacing: isNarrow ? 6 : 12) {
            transport
            display
                .frame(maxWidth: .infinity)
            trailing
        }
        // Measured on a flexible frame: the bar's own parts have fixed widths, and measuring
        // them would hold the bar at its old width.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: CGFloat(64).scaled)
        .glassEffect(.regular, in: .capsule)
        // The whole bar takes its clicks: through the glass between its buttons they reached the
        // page scrolling underneath, and a click beside the speaker played a song in the list.
        .contentShape(.capsule)
        // As wide as Music's at most, centred; a narrower window gets all of its width.
        .frame(maxWidth: CGFloat(940).scaled)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// The middle panel: the cover, the song centred over its progress, as Music's display.
    private var display: some View {
        HStack(spacing: 10) {
            Button { openNowPlaying() } label: {
                ArtworkView(artwork: player.current?.artwork, size: CGFloat(40).scaled, cornerRadius: 7)
                    .modifier(ZoomSource(namespace: zoom))
            }
            .buttonStyle(.plain)
            .help("Show Now Playing")
            VStack(spacing: 1) {
                Button { openNowPlaying() } label: {
                    HStack(spacing: 6) {
                        VStack(spacing: 0) {
                            Text(player.current?.title ?? "Not Playing")
                                .font(.scaled(.callout).weight(.semibold))
                            Text(player.current?.artistLine ?? " ")
                                .font(.scaled(.subheadline))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        if let mixing = player.mixing {
                            MixingBadge(mixing: mixing, compact: true)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                    .animation(.smooth(duration: 0.35), value: player.mixing)
                }
                .buttonStyle(.plain)
                .help("Show Now Playing")
                BarProgress()
            }
        }
        .padding(5)
        .padding(.trailing, 6)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
        .disabled(player.current == nil)
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
                .frame(width: isNarrow ? 28 : 120)
                .padding(.leading, isNarrow ? 0 : 6)
        }
    }

    private func iconButton(_ symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaledSystem(size: 14, weight: .semibold))
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
struct BarProgress: View {
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
            .font(.scaled(.caption2).monospacedDigit())
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
    /// Off in a narrow window: the speaker alone, which opens the slider in a popover.
    var showsSlider = true
    @Environment(Player.self) private var player
    @State private var hovering = false
    @State private var showsPopover = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if showsSlider { player.volume = player.volume > 0 ? 0 : 0.7 } else { showsPopover.toggle() }
            } label: {
                Image(systemName: symbol)
                    .font(.scaledSystem(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarButtonStyle())
            .help(showsSlider ? (player.volume > 0 ? "Mute" : "Unmute") : "Volume")
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                slider
                    .frame(width: 160)
                    .padding(14)
                    .presentationCompactAdaptation(.popover)
            }
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
            // As Music's: the playing song's album, or Now Playing for a song with none.
            Button("Go to Current Song") {
                guard let song = player.current else { return }
                if let album = song.album {
                    model.open(.album(AlbumSummary(id: album.id, title: album.title, artistLine: song.artistLine,
                                                   artists: song.artists, artwork: song.artwork)))
                } else {
                    model.isNowPlayingPresented = true
                }
            }
            .keyboardShortcut("l", modifiers: .command)
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
            Button("Radio") { model.go(to: .radio) }
                .keyboardShortcut("1", modifiers: [.command, .option])
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
        #if os(macOS)
        // Settings… (⌘,) is the Settings scene's own. One window is the whole app (a second would
        // play over the first), so File's New makes a playlist, as Music's does.
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { model.isNamingPlaylist = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        #else
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.isProfilePresented = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        // One window is the whole app; a second would play over the first.
        CommandGroup(replacing: .newItem) {}
        #endif
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

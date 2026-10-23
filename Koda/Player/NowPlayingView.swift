import KodaCore
import SwiftUI

/// The full-screen player.
struct NowPlayingView: View {
    enum Panel: Equatable {
        case artwork, lyrics, queue
    }

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeNowPlaying) private var closeNowPlaying
    @State private var panel: Panel = .artwork
    @Namespace private var artworkSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Room for the cover and the lyrics or queue side by side: a Mac window, an iPad in landscape.
    @State private var isWide = false

    var body: some View {
        ZStack {
            MeshBackground(palette: app.nowPlayingPalette.palette, isAnimating: player.wantsToPlay && app.settings.animatesPlayerBackground)
            if isWide { wideLayout } else { tallLayout }
        }
        // Escape closes the player, in either layout, as it closes a full view anywhere on the Mac.
        .background {
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 && $0.size.height >= 560 } action: { isWide = $0 }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: player.current == nil) { _, isEmpty in if isEmpty { close() } }
        .onChange(of: app.requestedPanel, initial: true) { _, requested in
            guard let requested else { return }
            app.requestedPanel = nil
            setPanel(requested)
        }
        .playlistPicker(whenOnTop: true)
    }

    /// The phone's player: one column, the cover giving way to lyrics or the queue.
    private var tallLayout: some View {
            VStack(spacing: 0) {
                topBar
                switch panel {
                case .artwork:
                    Spacer(minLength: 12)
                    bigArtwork
                    Spacer(minLength: 12)
                    titleRow
                case .lyrics:
                    compactHeader
                    LyricsPanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .queue:
                    compactHeader
                    QueuePanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if case .failed(let message) = player.phase {
                    FailureBanner(message: message) { player.resume() }
                        .padding(.top, 12)
                }
                Scrubber()
                    .padding(.top, 20)
                TransportControls()
                    .padding(.vertical, 18)
                VolumeSlider()
                    .frame(height: 34)
                bottomBar
                    .padding(.top, 14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .overlay {
                if player.current != nil { floatingArtwork }
            }
    }

    /// The wide player: the cover and controls hold the left, and lyrics or the queue open
    /// beside them instead of over the cover, as Music does on the Mac and iPad.
    private var wideLayout: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 28)
            HStack(spacing: 64) {
                VStack(spacing: 0) {
                    Spacer(minLength: 16)
                    bigArtwork
                    Spacer(minLength: 20)
                    titleRow
                    if case .failed(let message) = player.phase {
                        FailureBanner(message: message) { player.resume() }
                            .padding(.top, 12)
                    }
                    Scrubber()
                        .padding(.top, 16)
                    TransportControls()
                        .padding(.vertical, 12)
                    VolumeSlider()
                        .frame(height: 34)
                    bottomBar
                        .padding(.top, 10)
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: 440)
                .overlay {
                    if player.current != nil { floatingArtwork }
                }
                if panel != .artwork {
                    Group {
                        if panel == .lyrics { LyricsPanel() } else { QueuePanel() }
                    }
                    .frame(maxWidth: 620, maxHeight: .infinity)
                    .padding(.vertical, 16)
                    .transition(.opacity.combined(with: .offset(x: 40)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)
            .padding(.bottom, 16)
        }
    }

    /// Presented, it dismisses; on the Mac, where it is a layer of the window, the window closes it.
    private func close() {
        if let closeNowPlaying { closeNowPlaying() } else { dismiss() }
    }

    /// The song was asked for and no sound has come yet.
    private var isLoadingSong: Bool { player.isBuffering && player.phase == .loading }

    private var topBar: some View {
        HStack {
            if Platform.isMac {
                // A page on the Mac: the toolbar's back button and Esc close it.
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button { close() } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            Spacer()
            if app.sleepTimer.isActive {
                SleepTimerPill()
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                // The phone's grab handle; on the Mac the player closes with its button or Esc.
                if !Platform.isMac {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5)
                }
            }
            Spacer()
            if let song = player.current {
                Menu {
                    SongMenuItems(song: song)
                    Section {
                        SleepTimerMenu()
                        if panel == .lyrics { LyricsTimingMenu(songId: song.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.top, 8)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: app.sleepTimer.isActive)
    }

    /// Where the big cover goes. The cover itself is `floatingArtwork`, drawn once over
    /// the whole screen, so it moves and resizes between here and the compact header
    /// rather than fading out of one and into the other.
    private var bigArtwork: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Color.clear
                .frame(width: side, height: side)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var floatingArtwork: some View {
        let big = isWide || panel == .artwork
        let radius: CGFloat = big ? 18 : 8
        return ArtworkView(artwork: player.current?.artwork, size: 380, cornerRadius: radius, fillsFrame: true)
            // While the song loads the cover waits a little small, then settles to full size
            // the moment sound starts. Nothing is drawn over the art itself.
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(big ? (isLoadingSong ? 0.2 : 0.35) : 0.25), radius: big ? 30 : 8, y: big ? 18 : 4)
            // The cover breathes back when paused, like a record lifted off.
            .scaleEffect(big ? (player.wantsToPlay ? (isLoadingSong ? 0.93 : 1) : 0.84) : 1)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.wantsToPlay)
            // No bounce: sound arriving is not a gesture with momentum behind it.
            .animation(.smooth(duration: 0.45), value: isLoadingSong)
            .matchedGeometryEffect(id: "artwork", in: artworkSpace, isSource: false)
            .onTapGesture { if !big { setPanel(.artwork) } }
            .accessibilityHidden(true)
    }

    private var titleRow: some View {
        songLines(title: .title3.bold(), byline: .title3)
    }

    /// The byline: one artist opens at a tap, several offer a choice.
    private func artistButton(font: Font) -> some View {
        ArtistLinks(line: player.current?.artistLine ?? "", artists: player.current?.artists ?? [], open: { app.open(.artist($0)) }) {
            MarqueeText(text: player.current?.artistLine ?? "", font: font)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Title, byline and like button. A new song's lines fade in over the last one's, and
    /// lines too long to fit scroll sideways, as in Music.
    private func songLines(title: Font, byline: Font) -> some View {
        ZStack {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: player.current?.title ?? "", font: title)
                    artistButton(font: byline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let song = player.current {
                    LikeButton(song: song)
                }
            }
            .id(player.current?.id)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: player.current?.id)
    }

    /// The cover, title and like button in one row, above lyrics or the queue.
    private var compactHeader: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 64)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            songLines(title: .headline, byline: .subheadline)
        }
        .padding(.vertical, 16)
    }

    /// Lyrics, AirPlay and the queue, as plain symbols like the transport above them, each
    /// centred in the same third of the width as the control above it.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            panelButton(.lyrics, systemImage: "quote.bubble", activeImage: "quote.bubble.fill", label: "Lyrics")
                .frame(maxWidth: .infinity)
            AirPlayButton()
                .frame(width: 52, height: 40)
                .frame(maxWidth: .infinity)
            panelButton(.queue, systemImage: "list.bullet", activeImage: "list.bullet", label: "Queue")
                .frame(maxWidth: .infinity)
        }
    }

    /// `activeImage` is spelled out because not every symbol has a filled form; `list.bullet.fill` draws nothing.
    private func panelButton(_ target: Panel, systemImage: String, activeImage: String, label: String) -> some View {
        let active = panel == target
        return Button {
            setPanel(active ? .artwork : target)
        } label: {
            Image(systemName: active ? activeImage : systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 40)
        }
        .buttonStyle(PlayerToggleStyle(isOn: active))
        .sensoryFeedback(.selection, trigger: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// With Reduce Motion the panel changes in place, without the cover travelling across the screen.
    private func setPanel(_ next: Panel) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) { panel = next }
    }
}

/// The cover's colours as a slowly moving mesh. It holds still while paused so it costs nothing then.
struct MeshBackground: View {
    let palette: Palette
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isAnimating || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: palette.mesh)
        }
        .overlay(Color.black.opacity(0.18))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: palette)
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        // Only the inner points drift; the corners and edges stay put so the mesh always fills the screen.
        let a = Float(sin(t * 0.35)) * 0.12, b = Float(cos(t * 0.27)) * 0.12
        return [
            [0, 0], [0.5 + a * 0.5, 0], [1, 0],
            [0, 0.5 + b * 0.5], [0.5 + a, 0.5 + b], [1, 0.5 - a * 0.5],
            [0, 1], [0.5 - b * 0.5, 1], [1, 1],
        ]
    }
}

struct LikeButton: View {
    let song: Song
    @Environment(Library.self) private var library

    var body: some View {
        let liked = library.isLiked(song)
        Button {
            library.toggleLike(song)
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title3.weight(.semibold))
                .foregroundStyle(liked ? Color.pink : .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                // Drawn at the trailing edge of its tap area, so the heart lines up with the
                // end of the progress bar rather than sitting inside it.
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
        .accessibilityLabel(liked ? "Unlike" : "Like")
    }
}

/// Previous, play/pause and next, each centred in a third of the width, the same thirds
/// the bottom bar uses, so the two rows line up. With skip buttons on (Settings), they sit
/// at either end, smaller, and the row is shared five ways.
struct TransportControls: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var backs = 0
    @State private var forwards = 0
    @State private var rewinds = 0
    @State private var advances = 0

    var body: some View {
        let settings = app.settings
        let interval = settings.skipInterval
        HStack(spacing: 0) {
            if settings.showsSkipButtons {
                skipButton(interval.backSymbol, label: "Back \(interval.rawValue) Seconds", size: 24, taps: rewinds) {
                    rewinds += 1
                    player.skip(by: -interval.seconds)
                }
                .frame(maxWidth: .infinity)
                .disabled(player.phase != .ready)
            }
            skipButton("backward.fill", label: "Previous", taps: backs) {
                backs += 1
                player.previous()
            }
            .frame(maxWidth: .infinity)
            PlayPauseButton(size: 44)
                .frame(maxWidth: .infinity)
            skipButton("forward.fill", label: "Next", taps: forwards) {
                forwards += 1
                player.next()
            }
            .frame(maxWidth: .infinity)
            if settings.showsSkipButtons {
                skipButton(interval.forwardSymbol, label: "Ahead \(interval.rawValue) Seconds", size: 24, taps: advances) {
                    advances += 1
                    player.skip(by: interval.seconds)
                }
                .frame(maxWidth: .infinity)
                .disabled(player.phase != .ready)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: backs + forwards + rewinds + advances)
        .disabled(player.current == nil)
    }

    /// Only the pressed button answers: its own symbol bounces.
    private func skipButton(_ symbol: String, label: String, size: CGFloat = 32, taps: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .symbolEffect(.bounce.down, value: taps)
                // Up to 72 wide: five to a row still fits the narrowest iPhone.
                .frame(maxWidth: 72, minHeight: 60)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }
}

/// A soft circle behind the symbol while it is held, as Music's transport buttons show.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                    .frame(width: 64, height: 64)
            }
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Every toggle in Now Playing: white with a dark symbol while on, plain or faintly filled
/// while off. Drawn by Koda rather than with an interactive glass layer, which can take the
/// touch for itself so the button's action never runs.
struct PlayerToggleStyle: ButtonStyle {
    var isOn: Bool
    /// The fill behind the symbol while off: none for a lone symbol, faint for a row of toggles.
    var offFill: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(isOn ? Color.black : .white)
            .background {
                Capsule().fill(.white.opacity(isOn ? (pressed ? 0.85 : 1) : offFill + (pressed ? 0.12 : 0)))
            }
            .contentShape(.capsule)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.2), value: pressed)
            .animation(.smooth(duration: 0.25), value: isOn)
    }
}

private struct FailureBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).font(.footnote.weight(.semibold)).buttonStyle(.glass)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Time left on the sleep timer, at the top of Now Playing; a tap changes or ends it.
private struct SleepTimerPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            SleepTimerMenu()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(app.sleepTimer.label(at: context.date), systemImage: "moon.fill")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Sleep timer")
    }
}

/// Shift synced lyrics for the playing song, when they run ahead of or behind the singing.
private struct LyricsTimingMenu: View {
    let songId: String
    @Environment(Library.self) private var library

    var body: some View {
        let offset = library.lyricsOffset(for: songId)
        Menu {
            Button("Show Lyrics Earlier", systemImage: "backward") { library.setLyricsOffset(offset - 0.2, for: songId) }
            Button("Show Lyrics Later", systemImage: "forward") { library.setLyricsOffset(offset + 0.2, for: songId) }
            if offset != 0 {
                Button("Reset Timing", systemImage: "arrow.counterclockwise") { library.setLyricsOffset(0, for: songId) }
            }
        } label: {
            Label(offset == 0 ? "Lyrics Timing" : String(format: "Lyrics Timing (%+.1fs)", offset), systemImage: "timer")
        }
        // The menu stays open between steps, so the listener can nudge and watch the lyrics move.
        .menuActionDismissBehavior(.disabled)
    }
}

extension EnvironmentValues {
    /// Closes Now Playing when it is shown as part of a window rather than presented.
    @Entry var closeNowPlaying: (() -> Void)? = nil
}

import KodaCore
import SwiftUI

/// The bar above the tabs: what is playing, play/pause and skip. A tap opens Now Playing.
///
/// When the tab bar shrinks on scroll the system moves the accessory inline
/// beside it, where there is room for less, so the subtitle and skip go.
struct MiniPlayer: View {
    /// Opens Now Playing. Set by the view that presents it: the zoom from here only runs
    /// when that view's own state changes (see `RootView.showsNowPlaying`).
    let open: () -> Void
    @Environment(Player.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    /// How far the song has been dragged sideways; past `skipDistance` it skips.
    @State private var dragX: CGFloat = 0
    @State private var skips = 0
    private static let skipDistance: CGFloat = 64

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(artwork: player.current?.artwork, size: isInline ? 28 : 36, cornerRadius: isInline ? 6 : 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(player.current?.title ?? "Not Playing")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !isInline, let artist = player.current?.artistLine {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            }
            .offset(x: dragX)
            .opacity(1 - min(abs(dragX) / 160, 0.6))
            .contentShape(.rect)
            .gesture(swipe)
            .clipped()

            PlayPauseButton(size: 20)
            if !isInline {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(player.current == nil)
                .accessibilityLabel("Next")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .contentShape(.rect)
        .onTapGesture {
            guard player.current != nil else { return }
            open()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: skips)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing") { open() }
        .accessibilityAction(named: "Previous Song") { player.previous() }
        .accessibilityAction(named: "Next Song") { player.next() }
    }

    /// Swipe the song left for the next one, right for the one before, as Music's mini player does.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard player.current != nil, abs(value.translation.width) > abs(value.translation.height) else { return }
                // Resistance past the skip point, so the song never flies off under the finger.
                let x = value.translation.width
                let limit = Self.skipDistance * 1.6
                dragX = abs(x) < limit ? x : (x > 0 ? 1 : -1) * (limit + (abs(x) - limit) * 0.25)
            }
            .onEnded { value in
                let projected = value.predictedEndTranslation.width
                let forward = dragX < -Self.skipDistance || (dragX < -20 && projected < -Self.skipDistance * 2)
                let back = dragX > Self.skipDistance || (dragX > 20 && projected > Self.skipDistance * 2)
                guard forward || back, player.current != nil else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragX = 0 }
                    return
                }
                skips += 1
                // Out the way it was pushed, then the new song comes in from the other side.
                withAnimation(.easeIn(duration: 0.14)) { dragX = forward ? -220 : 220 } completion: {
                    if forward { player.next() } else { player.previous() }
                    dragX = forward ? 120 : -120
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { dragX = 0 }
                }
            }
    }
}

/// Play/pause; while the song loads a ring circles it and the glyph dims, so the
/// button still says what a tap will do.
struct PlayPauseButton: View {
    var size: CGFloat
    @Environment(Player.self) private var player
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            player.togglePlayPause()
        } label: {
            ZStack {
                Image(systemName: player.wantsToPlay ? "pause.fill" : "play.fill")
                    .font(.system(size: player.isBuffering ? size * 0.72 : size))
                    .opacity(player.isBuffering ? 0.75 : 1)
                    .contentTransition(.symbolEffect(.replace.downUp))
                if player.isBuffering {
                    BufferingRing(lineWidth: size > 30 ? 3 : 2)
                        .padding(size > 30 ? 4 : 3)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: size * 1.8, height: size * 1.8)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: player.isBuffering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(player.wantsToPlay ? "Pause" : "Play")
        .accessibilityValue(player.isBuffering ? "Loading" : "")
    }
}

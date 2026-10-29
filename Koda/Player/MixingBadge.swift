import KodaCore
import SwiftUI

/// Shown while AutoMix blends one song into the next, as Music shows "Mixing": a waveform
/// that moves for as long as the two songs overlap. Under the progress bar it is plain text;
/// on the Mac's player bar it sits in a small glass capsule.
struct MixingBadge: View {
    let mixing: Player.Mixing
    var compact = false
    var glass = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label("Mixing", systemImage: "waveform")
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeating, isActive: !reduceMotion)
            .font((compact ? Font.caption : .footnote).weight(.semibold))
            .padding(.horizontal, glass ? (compact ? 9 : 12) : 0)
            .frame(height: compact ? 22 : 30)
            .background {
                if glass { Capsule().fill(.clear).glassEffect(.regular, in: .capsule) }
            }
            .help("AutoMix is blending into \(mixing.to)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AutoMix, mixing into \(mixing.to)")
    }
}

/// The Now Playing cover through an AutoMix transition: the old cover dissolves outwards
/// (a little larger, blurring, fading) as the new one settles up from just below full size,
/// over exactly the time the two songs overlap. While beats are locked the pair gives the
/// faintest pulse on the shared beat. Reduce Motion keeps only the crossfade.
struct MixingCovers: View {
    let artwork: Artwork?
    let mixing: Player.Mixing?
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: mixing == nil)) { context in
            let progress = mixing?.progress(at: context.date) ?? 1
            // Smoothstep: the handover eases in and out like the audio's own curves.
            let eased = progress * progress * (3 - 2 * progress)
            ZStack {
                ArtworkView(artwork: artwork, size: 380, cornerRadius: cornerRadius, fillsFrame: true)
                    .scaleEffect(reduceMotion ? 1 : 0.95 + 0.05 * eased)
                if let mixing, progress < 1 {
                    ArtworkView(artwork: mixing.fromArtwork, size: 380, cornerRadius: cornerRadius, fillsFrame: true)
                        .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * eased)
                        .blur(radius: reduceMotion ? 0 : 18 * eased)
                        .opacity(1 - eased)
                }
            }
            .scaleEffect(reduceMotion ? 1 : beatPulse(at: context.date, progress: progress))
        }
    }

    /// Up 1.2 % on each locked beat, decaying within the beat; nothing outside a transition.
    private func beatPulse(at date: Date, progress: Double) -> Double {
        guard let mixing, mixing.style == .beatMatch, let beat = mixing.beat, let period = mixing.beatPeriod,
              period > 0, progress < 1 else { return 1 }
        let since = date.timeIntervalSince(beat)
        guard since >= 0 else { return 1 }
        let phase = since.truncatingRemainder(dividingBy: period) / period
        // Strongest mid-blend, easing in and out with the transition.
        let presence = sin(progress * .pi)
        return 1 + 0.012 * exp(-phase * 6) * presence
    }
}

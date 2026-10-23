import SwiftUI

/// An arc that circles a control while the song it controls is loading.
struct BufferingRing: View {
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // The arc turns steadily and breathes in length, so it reads as busy rather than stuck.
            let length = 0.18 + 0.14 * (1 + sin(t * 2.4)) / 2
            Circle()
                .trim(from: 0, to: reduceMotion ? 0.3 : length)
                .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : (t * 300).truncatingRemainder(dividingBy: 360)))
        }
        .opacity(reduceMotion ? 0.6 : 0.9)
        .accessibilityHidden(true)
    }
}

/// A soft highlight drifting across content while it loads, as the system shimmers text
/// that is still coming. It is masked to the content's own shapes, so only what is loading
/// catches the light, never the space around it. Every shimmer reads one clock, so a
/// loading page passes as one sweep rather than many blinking parts. It holds still with
/// Reduce Motion on.
struct Shimmer: ViewModifier {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Seconds for the light to cross, then a rest before the next pass.
    private static let sweep = 1.5
    private static let rest = 0.9

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                TimelineView(.animation) { context in
                    let cycle = Self.sweep + Self.rest
                    let progress = min(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / Self.sweep, 1)
                    // The band is one view wide and its centre runs from half a width before the
                    // leading edge to half a width past the trailing one: it enters and leaves unseen.
                    let centre = -0.5 + progress * 2
                    LinearGradient(stops: Self.stops(peak: colorScheme == .dark ? 0.1 : 0.4),
                                   startPoint: UnitPoint(x: centre - 0.5, y: 0.5),
                                   endPoint: UnitPoint(x: centre + 0.5, y: 0.5))
                }
                .mask { content }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }

    /// A bell-shaped falloff, so the highlight has no edge anywhere.
    private static func stops(peak: Double) -> [Gradient.Stop] {
        [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(peak * 0.3), location: 0.3),
            .init(color: .white.opacity(peak), location: 0.5),
            .init(color: .white.opacity(peak * 0.3), location: 0.7),
            .init(color: .white.opacity(0), location: 1),
        ]
    }
}

extension View {
    func shimmer(_ isActive: Bool = true) -> some View {
        modifier(Shimmer(isActive: isActive))
    }
}

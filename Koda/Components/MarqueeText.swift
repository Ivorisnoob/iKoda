import SwiftUI

/// One line of text that, when too long for its space, scrolls sideways to show the rest and
/// comes back round to its start, resting there between passes, as Music's player does with
/// long titles. With Reduce Motion on it is truncated instead.
struct MarqueeText: View {
    let text: String
    var font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling = false

    /// Space between the end of the text and its next copy.
    private static let gap: CGFloat = 36
    /// Points per second; slow enough to read while it moves.
    private static let speed: CGFloat = 32
    private static let rest: Duration = .seconds(2.5)
    private static let fade: CGFloat = 14

    private var overflows: Bool { !reduceMotion && textWidth > boxWidth + 1 }

    var body: some View {
        // The truncated line sets the height and takes the width offered; it is what shows
        // when the text fits.
        Text(text)
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(overflows ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background {
                Text(text)
                    .font(font)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if overflows {
                    HStack(spacing: Self.gap) {
                        Text(text)
                        Text(text)
                    }
                    .font(font)
                    .fixedSize()
                    .offset(x: offset)
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
                    .mask { edgeFade }
                    .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .task(id: ScrollKey(text: text, overflows: overflows, distance: textWidth + Self.gap)) {
                await scroll()
            }
    }

    /// The text fades out at the far edge, and at the near edge only while it moves, so at
    /// rest its first letter sits sharp at the start of the line.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fade)
                .opacity(isScrolling ? 1 : 0)
                .background(Color.black.opacity(isScrolling ? 0 : 1))
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fade)
        }
    }

    private func scroll() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            offset = 0
            isScrolling = false
        }
        guard overflows else { return }
        let distance = textWidth + Self.gap
        let duration = Double(distance / Self.speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rest)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isScrolling = true }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The second copy now sits where the first began, so jumping back is invisible.
            withTransaction(still) { offset = 0 }
            withAnimation(.easeInOut(duration: 0.2)) { isScrolling = false }
        }
    }
}

private struct ScrollKey: Equatable {
    var text: String
    var overflows: Bool
    var distance: CGFloat
}

import KodaCore
import SwiftUI

/// Cover art at a fixed size: square, rounded, or a circle for artists.
///
/// A video thumbnail (16:9) is cropped to the square, so every row and card
/// keeps the same shape whatever YouTube served.
struct ArtworkView: View {
    var artwork: Artwork?
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    var circle = false
    /// Fill whatever frame it is given instead of `size`, which then only sets the pixels loaded.
    var fillsFrame = false

    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    private var pixels: Int { Int((size * scale).rounded(.up)) }
    private var url: URL? { artwork?.url(pixels: max(pixels, 120)) }

    var body: some View {
        // The frame is laid out by a plain shape; the image is an overlay cropped to it. A
        // scaled-to-fill image laid out directly reports its own, wider size, which pushed a
        // video's 16:9 thumbnail out past the frame's leading edge.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if image == nil {
                    Image(systemName: circle ? "music.mic" : "music.note")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // A video's thumbnail is 4:3 with the 16:9 picture letterboxed inside: enlarged
                        // to the picture's height, the bars fall outside the square instead of edging it.
                        .scaleEffect(isLetterboxed(image) ? 4.0 / 3.0 : 1)
                        .transition(.opacity)
                }
            }
            .frame(width: fillsFrame ? nil : size, height: fillsFrame ? nil : size)
            .frame(maxWidth: fillsFrame ? .infinity : nil, maxHeight: fillsFrame ? .infinity : nil)
            .clipShape(shape)
        // A hairline so a white cover keeps its edge on a white page. Black, and only in light
        // mode: drawn in the primary colour it was a bright ring around dark covers in dark mode.
        .overlay {
            if colorScheme == .light { shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImagePipeline.shared.cached(url, pixels: pixels) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(url, pixels: pixels)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }

    /// YouTube's video thumbnails (i.ytimg.com) come 4:3, with black bars above and below the picture.
    private func isLetterboxed(_ image: UIImage) -> Bool {
        guard let host = url?.host(), host.contains("ytimg.com"), image.size.height > 0 else { return false }
        return abs(image.size.width / image.size.height - 4.0 / 3.0) < 0.02
    }

    private var shape: AnyInsettableShape {
        circle ? AnyInsettableShape(Circle()) : AnyInsettableShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A type-erased insettable shape, so one view can be clipped by a circle or a rounded square.
nonisolated struct AnyInsettableShape: InsettableShape {
    private let pathBuilder: @Sendable (CGRect) -> Path
    private let insetBuilder: @Sendable (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        pathBuilder = { shape.path(in: $0) }
        insetBuilder = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { insetBuilder(amount) }
}

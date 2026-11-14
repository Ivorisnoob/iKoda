import ImageIO
import SwiftUI
import WidgetKit

// What Koda's widgets share: its colours, covers read from the shared folder, and the
// backgrounds. Plain SwiftUI and ImageIO, so the same views draw on the iPhone and the Mac.

extension Color {
    /// The app's accent, as its asset catalog has it, and its light-mode partner.
    static let koda = Color(red: 0x3D / 255, green: 0x5A / 255, blue: 0xFE / 255)
    static let kodaLight = Color(red: 0x86 / 255, green: 0x9C / 255, blue: 0xFF / 255)
    /// The brand's indigo, ink and lime.
    static let kodaIndigo = Color(red: 0x3A / 255, green: 0x2E / 255, blue: 0xA6 / 255)
    static let kodaInk = Color(red: 0x15 / 255, green: 0x12 / 255, blue: 0x3F / 255)
    static let kodaLime = Color(red: 0x9B / 255, green: 0xE8 / 255, blue: 0x3F / 255)
}

enum WidgetArt {
    /// A cover the app wrote, decoded here: the extension has neither the app's image pipeline
    /// nor, on the Mac, UIKit.
    static func image(_ name: String?) -> Image? {
        guard let url = SharedContainer.cover(name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

/// A song's cover, square and rounded; a note while it hasn't been fetched.
struct WidgetCover: View {
    let name: String?
    var radius: CGFloat = 12

    var body: some View {
        Color.white.opacity(0.14)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = WidgetArt.image(name) {
                    image
                        .resizable()
                        // Tinted and clear Home Screens, and the Mac's dimmed desktop, keep the cover as it is.
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// The cover's own colours as a soft 3×3 mesh, as Now Playing's background is in the app,
/// deepened toward the foot so white type always reads; Koda's indigo with no cover.
struct CoverBackground: View {
    let colors: [WidgetColor]?

    var body: some View {
        ZStack {
            if let colors, colors.count == 9 {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: colors.map(\.color))
            } else {
                KodaBackground()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
        }
    }
}

/// Koda's own colours: indigo deepening into ink.
struct KodaBackground: View {
    var body: some View {
        LinearGradient(colors: [.kodaIndigo, .kodaInk], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A small heading over a widget's content, as Music's and Fitness's widgets label theirs.
struct WidgetEyebrow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.72))
            .labelStyle(EyebrowLabelStyle())
    }

    private struct EyebrowLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}

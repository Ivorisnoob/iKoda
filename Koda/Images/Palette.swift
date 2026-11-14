import KodaCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Colours taken from a cover, for the player background and tinted buttons.
struct Palette: Equatable, Sendable {
    /// Nine colours in reading order, one per cell of the cover shrunk to 3×3; the points of a 3×3 mesh.
    var mesh: [Color]
    /// The most colourful of them, brightened enough to read as a button.
    var accent: Color
    /// Whether the background is light enough to need dark text.
    var isLight: Bool

    static let fallback = Palette(
        mesh: Array(repeating: Color(white: 0.16), count: 9),
        accent: .accentColor,
        isLight: false)
}

enum PaletteExtractor {
    static func palette(for image: PlatformImage) -> Palette {
        guard let cg = image.cgImage else { return .fallback }
        // The cover drawn into 3×3 pixels averages each region of it.
        var pixels = [UInt8](repeating: 0, count: 9 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return true
        }
        guard drawn else { return .fallback }

        var colors: [PlatformColor] = []
        for i in 0..<9 {
            let r = CGFloat(pixels[i * 4]) / 255, g = CGFloat(pixels[i * 4 + 1]) / 255, b = CGFloat(pixels[i * 4 + 2]) / 255
            colors.append(PlatformColor(red: r, green: g, blue: b, alpha: 1))
        }
        // Darken for white text; a pale cover still reads as itself, only deeper.
        let mesh = colors.map { color -> Color in
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            return Color(hue: h, saturation: min(1, s * 1.15), brightness: min(v, 0.62) * 0.85 + 0.05)
        }
        let vivid = colors.max { saturation($0) * brightness($0) < saturation($1) * brightness($1) } ?? colors[4]
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        vivid.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let accent = s < 0.15 ? Color.white : Color(hue: h, saturation: min(0.85, max(s, 0.45)), brightness: max(v, 0.85))
        return Palette(mesh: mesh, accent: accent, isLight: false)
    }

    private static func saturation(_ c: PlatformColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return s
    }

    private static func brightness(_ c: PlatformColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return v
    }
}

/// Loads the palette of `artwork`, keeping the previous one until the new one is ready.
@MainActor
@Observable
final class PaletteModel {
    private(set) var palette: Palette = .fallback
    private var loadedFor: URL?

    func load(_ artwork: Artwork?) async {
        guard let url = artwork?.url(pixels: 200), url != loadedFor else { return }
        loadedFor = url
        guard let image = await ImagePipeline.shared.image(url, pixels: 200) else { return }
        let next = PaletteExtractor.palette(for: image)
        guard loadedFor == url else { return }
        withAnimation(.easeInOut(duration: 0.6)) { palette = next }
    }
}

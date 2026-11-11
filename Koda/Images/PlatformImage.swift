import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit

/// The platform's own image and colour classes: UIKit's on the iPhone (and Catalyst), AppKit's
/// in the native Mac app. Koda only needs what both share: an image made from a CGImage or
/// data, its size, and its CGImage.
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

extension NSImage {
    /// As UIKit's: one point per pixel.
    nonisolated convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#else
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// The window's own background: the page colour things fade into.
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Hue, saturation and brightness, or nil for a colour that has none (a pattern). AppKit
    /// answers only for RGB colours, so the colour is resolved into sRGB first.
    var hsb: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        #endif
        return (h, s, b)
    }
}

extension ImageRenderer {
    var platformImage: PlatformImage? {
        #if os(macOS)
        nsImage
        #else
        uiImage
        #endif
    }
}

enum PlatformImages {
    /// Puts the image on the clipboard.
    static func copy(_ image: PlatformImage) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #else
        UIPasteboard.general.image = image
        #endif
    }

    /// A picked photo cropped to its centre square, at most `maxSide` pixels wide, as JPEG; nil
    /// if it isn't an image. Done with ImageIO, so it is the same on every platform and never
    /// decodes the full photo.
    nonisolated static func squareJPEG(_ data: Data, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // The thumbnail's longest side is chosen so its shortest is the square's side.
        let side = min(width, height)
        let target = min(maxSide, side)
        let longest = Int((Double(max(width, height)) * Double(target) / Double(side)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let square = min(scaled.width, scaled.height)
        let crop = CGRect(x: (scaled.width - square) / 2, y: (scaled.height - square) / 2, width: square, height: square)
        guard let cropped = scaled.cropping(to: crop) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

// Draws the picture behind the Koda disk image's window: run
// `swift Packaging/dmg-background.swift Packaging` from the repository root after
// changing it, and commit the result (Packaging/dmg-background.tiff). CI only uses that file.
//
// The window is `size` points; Finder lays the two icons over the places left for them
// (`appCenter`, `applicationsCenter`, kept in step with make-dmg.sh).

import AppKit
import SwiftUI

let size = CGSize(width: 640, height: 420)
let appCenter = CGPoint(x: 176, y: 214)
let applicationsCenter = CGPoint(x: 464, y: 214)

extension Color {
    static let indigo = Color(red: 0x3A / 255, green: 0x2E / 255, blue: 0xA6 / 255)
    static let lavender = Color(red: 0xEF / 255, green: 0xED / 255, blue: 0xF9 / 255)
    static let lavenderDeep = Color(red: 0xE0 / 255, green: 0xDC / 255, blue: 0xF5 / 255)
}

/// Koda's mark without its backdrop: the tall bar and the play triangle beside it.
struct Mark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: w * 0.3, height: h),
                            cornerSize: CGSize(width: w * 0.15, height: w * 0.15), style: .continuous)
        // The triangle, its corners softened as the icon's are.
        let top = CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.3)
        let tip = CGPoint(x: rect.maxX, y: rect.minY + h * 0.5)
        let bottom = CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.7)
        let r = w * 0.06
        path.move(to: CGPoint(x: top.x, y: top.y + r))
        path.addArc(tangent1End: top, tangent2End: tip, radius: r)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: r)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: r)
        path.closeSubpath()
        return path
    }
}

/// The hairline from one icon toward the other.
struct Arrow: Shape {
    var head: CGFloat = 7
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = appCenter.y
        let start = appCenter.x + 88, end = applicationsCenter.x - 88
        path.move(to: CGPoint(x: start, y: y))
        path.addLine(to: CGPoint(x: end, y: y))
        if head > 0 {
            path.move(to: CGPoint(x: end - head, y: y - head))
            path.addLine(to: CGPoint(x: end, y: y))
            path.addLine(to: CGPoint(x: end - head, y: y + head))
        }
        return path
    }
}

/// The whole window a pale tint of Koda's indigo (light, so Finder's icon labels, always drawn
/// in black, read on it), the mark huge in a deeper tint behind, the type and arrow in indigo.
struct LavenderStyle: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.lavender
            Mark()
                .fill(Color.lavenderDeep)
                .frame(width: 330, height: 420)
                .offset(x: 360, y: 40)
            Text("Koda")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Color.indigo)
                .offset(x: 32, y: 28)
            Text("Drag into Applications to install")
                .font(.system(size: 12))
                .foregroundStyle(Color.indigo.opacity(0.6))
                .offset(x: 32, y: 58)
            Arrow(head: 6)
                .stroke(Color.indigo, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            Text("On first launch, choose Open Anyway in System Settings › Privacy & Security.")
                .font(.system(size: 11))
                .foregroundStyle(Color.indigo.opacity(0.6))
                .frame(width: size.width)
                .offset(y: size.height - 40)
        }
    }
}

struct Background: View {
    var body: some View {
        LavenderStyle()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .light)
    }
}

@MainActor
func render(scale: CGFloat) -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let cgImage = renderer.cgImage else { fatalError("Couldn't draw the background") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    // Points, not pixels: Finder picks the 2× one on a Retina screen.
    rep.size = size
    return rep
}

let arguments = CommandLine.arguments
let folder = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Packaging")
let tiff = MainActor.assumeIsolated { () -> Data in
    let reps = [render(scale: 1), render(scale: 2)]
    guard let data = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]) else {
        fatalError("Couldn't write the TIFF")
    }
    return data
}
try tiff.write(to: folder.appending(path: "dmg-background.tiff"))
print("Wrote dmg-background.tiff")

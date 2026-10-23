import KodaCore
import SwiftUI
import UIKit

/// One of Koda's drawn avatars: a coloured shape with a face on it.
///
/// Everything is a fraction of the avatar's own size, so the same avatar is right at 28 points
/// in the toolbar and at 120 on the profile page. The face sits in the middle half, clear of
/// every outline's edge, which is what lets the nine shapes share one face. One Canvas pass,
/// nothing measured: cheap enough for every row of a list.
struct KodaAvatarView: View {
    let avatar: KodaAvatar
    let size: CGFloat

    var body: some View {
        let colors = avatar.colorway
        Canvas { context, canvas in
            let face = AvatarFace(size: canvas, ink: Color(colors.ink), fill: Color(colors.fill), blush: Color(colors.blush))
            context.fill(AvatarOutline(shape: avatar.shapeIndex).path(in: CGRect(origin: .zero, size: canvas)), with: .color(face.fill))
            if avatar.blush { face.drawBlush(in: &context) }
            face.drawExtraBehind(avatar.extraIndex, in: &context)
            face.drawEyes(avatar.eyesIndex, in: &context)
            face.drawMouth(avatar.mouthIndex, in: &context)
            face.drawExtraFront(avatar.extraIndex, in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(_ rgb: KodaAvatar.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// The outline an avatar is cut to: a circle, or a soft scalloped shape in the spirit of
/// Material's cookies and flowers, which Koda for Android uses for the same nine indices.
nonisolated struct AvatarOutline: Shape {
    let shape: Int

    /// Lobes and how deep they go, by index.
    private var wave: (lobes: Int, depth: CGFloat, rotation: CGFloat) {
        switch shape {
        case 1: (9, 0.055, 0)       // cookie, nine-sided
        case 2: (8, 0.13, 0)        // flower
        case 3: (6, 0.07, 0)        // cookie, six-sided
        case 4: (4, 0.17, .pi / 4) // clover
        case 5: (12, 0.04, 0)       // cookie, twelve-sided
        case 6: (10, 0.085, 0)      // soft burst
        case 7: (4, 0.08, 0)        // cookie, four-sided
        case 8: (8, 0.065, .pi / 8) // sunny
        default: (0, 0, 0)          // circle
        }
    }

    func path(in rect: CGRect) -> Path {
        let (lobes, depth, rotation) = wave
        guard lobes > 0 else { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // The wave peaks at the frame's edge, so every shape fills the same square.
        let outer = min(rect.width, rect.height) / 2
        let base = outer / (1 + depth)
        var path = Path()
        let steps = 180
        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let radius = base * (1 + depth * cos(CGFloat(lobes) * (angle - rotation)))
            let point = CGPoint(x: center.x + radius * cos(angle - .pi / 2), y: center.y + radius * sin(angle - .pi / 2))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The face's parts, drawn as Koda for Android draws them: positions and sizes as fractions
/// of the avatar, angles in degrees clockwise from three o'clock.
nonisolated private struct AvatarFace {
    let size: CGSize
    let ink: Color
    let fill: Color
    let blush: Color

    static let eyeY: CGFloat = 0.45
    static let eyeLeft: CGFloat = 0.37
    static let eyeRight: CGFloat = 0.63
    static let mouthY: CGFloat = 0.60

    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: size.width * x, y: size.height * y) }
    func unit(_ value: CGFloat) -> CGFloat { min(size.width, size.height) * value }
    func line(_ width: CGFloat = 0.035) -> StrokeStyle { StrokeStyle(lineWidth: unit(width), lineCap: .round) }

    func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// An arc of the ellipse in `rect`; `closed` joins it through the centre, as a filled half.
    func arc(_ origin: CGPoint, width: CGFloat, height: CGFloat, start: CGFloat, sweep: CGFloat, closed: Bool = false) -> Path {
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        if closed { path.move(to: center) }
        let steps = 24
        for step in 0...steps {
            let degrees = start + sweep * CGFloat(step) / CGFloat(steps)
            let radians = degrees * .pi / 180
            let point = CGPoint(x: center.x + rect.width / 2 * cos(radians), y: center.y + rect.height / 2 * sin(radians))
            if step == 0 && !closed { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed { path.closeSubpath() }
        return path
    }

    func segment(_ from: CGPoint, _ to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    func drawBlush(in context: inout GraphicsContext) {
        context.fill(circle(at(0.28, 0.57), unit(0.065)), with: .color(blush.opacity(0.45)))
        context.fill(circle(at(0.72, 0.57), unit(0.065)), with: .color(blush.opacity(0.45)))
    }

    func drawEyes(_ kind: Int, in context: inout GraphicsContext) {
        let y = Self.eyeY
        func dot(_ x: CGFloat) { context.fill(circle(at(x, y), unit(0.042)), with: .color(ink)) }
        // An arc opening downward: a closed, smiling eye.
        func smile(_ x: CGFloat) {
            context.stroke(arc(at(x - 0.055, y - 0.035), width: unit(0.11), height: unit(0.09), start: 200, sweep: 140), with: .color(ink), style: line())
        }
        switch kind {
        case 0: dot(Self.eyeLeft); dot(Self.eyeRight)
        case 1: smile(Self.eyeLeft); smile(Self.eyeRight)
        case 2: dot(Self.eyeLeft); smile(Self.eyeRight)
        case 3:
            // Big and shiny: a highlight cut out of the pupil in the fill colour.
            for x in [Self.eyeLeft, Self.eyeRight] {
                context.fill(circle(at(x, y), unit(0.062)), with: .color(ink))
                context.fill(circle(at(x + 0.02, y - 0.022), unit(0.022)), with: .color(fill))
            }
        case 4:
            // Sleepy: a short flat line.
            for x in [Self.eyeLeft, Self.eyeRight] {
                context.stroke(segment(at(x - 0.045, y), at(x + 0.045, y)), with: .color(ink), style: line())
            }
        default:
            // Tall ovals.
            for x in [Self.eyeLeft, Self.eyeRight] {
                let origin = at(x - 0.032, y - 0.06)
                context.fill(Path(ellipseIn: CGRect(x: origin.x, y: origin.y, width: unit(0.064), height: unit(0.12))), with: .color(ink))
            }
        }
    }

    func drawMouth(_ kind: Int, in context: inout GraphicsContext) {
        let y = Self.mouthY
        switch kind {
        case 0:
            context.stroke(arc(at(0.42, y - 0.06), width: unit(0.16), height: unit(0.11), start: 20, sweep: 140), with: .color(ink), style: line())
        case 1:
            // Open and happy: a filled half.
            context.fill(arc(at(0.41, y - 0.075), width: unit(0.18), height: unit(0.15), start: 0, sweep: 180, closed: true), with: .color(ink))
        case 2:
            // The cat's ":3": two small bowls meeting in the middle.
            context.stroke(arc(at(0.42, y - 0.035), width: unit(0.08), height: unit(0.07), start: 0, sweep: 180), with: .color(ink), style: line())
            context.stroke(arc(at(0.50, y - 0.035), width: unit(0.08), height: unit(0.07), start: 0, sweep: 180), with: .color(ink), style: line())
        case 3:
            context.stroke(segment(at(0.45, y + 0.01), at(0.55, y + 0.01)), with: .color(ink), style: line())
        case 4:
            context.stroke(circle(at(0.5, y + 0.01), unit(0.035)), with: .color(ink), style: line(0.03))
        default:
            // A grin with the tongue out.
            context.stroke(arc(at(0.42, y - 0.06), width: unit(0.16), height: unit(0.11), start: 20, sweep: 140), with: .color(ink), style: line())
            context.fill(circle(at(0.53, y + 0.055), unit(0.032)), with: .color(blush))
        }
    }

    /// Extras that sit behind the face.
    func drawExtraBehind(_ kind: Int, in context: inout GraphicsContext) {
        switch kind {
        case 1:
            // Headphones: a band over the top and a cup at each ear.
            context.stroke(arc(at(0.22, 0.20), width: unit(0.56), height: unit(0.52), start: 180, sweep: 180), with: .color(ink), style: line(0.045))
            for x in [0.16, 0.74] as [CGFloat] {
                let origin = at(x, 0.40)
                context.fill(Path(roundedRect: CGRect(x: origin.x, y: origin.y, width: unit(0.10), height: unit(0.17)), cornerRadius: unit(0.04)), with: .color(blush))
            }
        case 3:
            // A sprout: a stem and two leaves.
            context.stroke(segment(at(0.5, 0.30), at(0.5, 0.20)), with: .color(ink), style: line(0.03))
            for x in [0.41, 0.50] as [CGFloat] {
                let origin = at(x, 0.155)
                context.fill(Path(ellipseIn: CGRect(x: origin.x, y: origin.y, width: unit(0.09), height: unit(0.055))), with: .color(blush))
            }
        case 4:
            // A bow: two wings and a knot.
            var bow = Path()
            bow.move(to: at(0.5, 0.235)); bow.addLine(to: at(0.38, 0.175)); bow.addLine(to: at(0.38, 0.295)); bow.closeSubpath()
            bow.move(to: at(0.5, 0.235)); bow.addLine(to: at(0.62, 0.175)); bow.addLine(to: at(0.62, 0.295)); bow.closeSubpath()
            context.fill(bow, with: .color(blush))
            context.fill(circle(at(0.5, 0.235), unit(0.025)), with: .color(ink))
        default:
            break
        }
    }

    /// Extras that sit over the face.
    func drawExtraFront(_ kind: Int, in context: inout GraphicsContext) {
        switch kind {
        case 2:
            // A sparkle: a four-point star up and to the side.
            let c = at(0.74, 0.27), long = unit(0.075), short = unit(0.022)
            var star = Path()
            star.move(to: CGPoint(x: c.x, y: c.y - long))
            star.addLine(to: CGPoint(x: c.x + short, y: c.y - short))
            star.addLine(to: CGPoint(x: c.x + long, y: c.y))
            star.addLine(to: CGPoint(x: c.x + short, y: c.y + short))
            star.addLine(to: CGPoint(x: c.x, y: c.y + long))
            star.addLine(to: CGPoint(x: c.x - short, y: c.y + short))
            star.addLine(to: CGPoint(x: c.x - long, y: c.y))
            star.addLine(to: CGPoint(x: c.x - short, y: c.y - short))
            star.closeSubpath()
            context.fill(star, with: .color(blush))
        case 5:
            // Round glasses.
            context.stroke(circle(at(Self.eyeLeft, Self.eyeY), unit(0.085)), with: .color(ink), style: line(0.025))
            context.stroke(circle(at(Self.eyeRight, Self.eyeY), unit(0.085)), with: .color(ink), style: line(0.025))
            context.stroke(segment(at(Self.eyeLeft + 0.085, Self.eyeY), at(Self.eyeRight - 0.085, Self.eyeY)), with: .color(ink), style: line(0.025))
        default:
            break
        }
    }
}

#Preview {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 5)) {
        ForEach(0..<20, id: \.self) { index in
            KodaAvatarView(avatar: .seeded("preview-\(index)"), size: 56)
        }
    }
    .padding()
}

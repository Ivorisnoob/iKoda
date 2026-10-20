import KodaCore
import SwiftUI

/// One of Koda's drawn avatars: a coloured shape with a face on it.
///
/// Everything is drawn as a fraction of the avatar's own size, so the same
/// avatar is right at 28 points in a row and at 112 on the profile screen. The
/// face sits in the middle half of the shape, clear of every outline's edge,
/// which is what lets the shapes share one face.
///
/// Its colours are the avatar's own, not the theme's: an avatar is somebody's
/// picture, and it has to be the same peach face in the dark theme, in the
/// light one and under an album's palette.
struct KodaAvatarView: View {
    let avatar: KodaAvatar
    var size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas.size)
            let colours = KodaAvatarColours.colour(avatar.color)
            let fill = Color(red: red(colours.fill), green: green(colours.fill), blue: blue(colours.fill))
            let ink = Color(red: red(colours.ink), green: green(colours.ink), blue: blue(colours.ink))
            let blush = Color(red: red(colours.blush), green: green(colours.blush), blue: blue(colours.blush))

            let outline = KodaAvatarOutline(kind: avatar.shape)
            let shape = outline.path(in: rect)
            context.fill(shape, with: .color(fill))

            func unit(_ value: CGFloat) -> CGFloat { min(rect.width, rect.height) * value }
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.width * x, y: rect.height * y) }
            func line(_ width: CGFloat = 0.035) -> StrokeStyle {
                StrokeStyle(lineWidth: unit(width), lineCap: .round, lineJoin: .round)
            }

            if avatar.blush {
                for x in [CGFloat(0.28), CGFloat(0.72)] {
                    let dot = Path(ellipseIn: CGRect(x: rect.width * x - unit(0.065), y: rect.height * 0.57 - unit(0.065),
                                                     width: unit(0.13), height: unit(0.13)))
                    context.fill(dot, with: .color(blush.opacity(0.45)))
                }
            }

            drawExtraBehind(context, ink: ink, blush: blush, unit: unit, at: at, line: line)
            drawEyes(context, ink: ink, fill: fill, unit: unit, at: at, line: line)
            drawMouth(context, ink: ink, blush: blush, unit: unit, at: at, line: line)
            drawExtraFront(context, ink: ink, blush: blush, unit: unit, at: at, line: line)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Colours

    private func red(_ value: UInt32) -> Double { Double((value >> 16) & 0xFF) / 255 }
    private func green(_ value: UInt32) -> Double { Double((value >> 8) & 0xFF) / 255 }
    private func blue(_ value: UInt32) -> Double { Double(value & 0xFF) / 255 }

    // MARK: The face

    private let eyeY: CGFloat = 0.45
    private let eyeLeft: CGFloat = 0.37
    private let eyeRight: CGFloat = 0.63
    private let mouthY: CGFloat = 0.60

    private func drawEyes(_ context: GraphicsContext, ink: Color, fill: Color,
                          unit: (CGFloat) -> CGFloat, at: (CGFloat, CGFloat) -> CGPoint,
                          line: (CGFloat) -> StrokeStyle) {
        func dot(_ x: CGFloat, _ radius: CGFloat = 0.042) {
            let centre = at(x, eyeY)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - unit(radius), y: centre.y - unit(radius),
                                                width: unit(radius) * 2, height: unit(radius) * 2)),
                         with: .color(ink))
        }
        // An arc opening downward: a closed, smiling eye.
        func smile(_ x: CGFloat) {
            let centre = at(x, eyeY)
            var path = Path()
            path.addArc(center: CGPoint(x: centre.x, y: centre.y - unit(0.012)),
                        radius: unit(0.05), startAngle: .degrees(20), endAngle: .degrees(160),
                        clockwise: false)
            context.stroke(path, with: .color(ink), style: line())
        }
        switch ((avatar.eyes % KodaAvatar.eyeCount) + KodaAvatar.eyeCount) % KodaAvatar.eyeCount {
        case 0:
            dot(eyeLeft); dot(eyeRight)
        case 1:
            smile(eyeLeft); smile(eyeRight)
        case 2:
            dot(eyeLeft); smile(eyeRight)
        case 3:
            // Big and shiny: a highlight cut out of the pupil in the fill colour.
            for x in [eyeLeft, eyeRight] {
                let centre = at(x, eyeY)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - unit(0.062), y: centre.y - unit(0.062),
                                                    width: unit(0.124), height: unit(0.124))), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: centre.x + unit(0.02) - unit(0.022), y: centre.y - unit(0.022) - unit(0.022),
                                                    width: unit(0.044), height: unit(0.044))), with: .color(fill))
            }
        case 4:
            // Sleepy: a short flat line.
            for x in [eyeLeft, eyeRight] {
                let centre = at(x, eyeY)
                var path = Path()
                path.move(to: CGPoint(x: centre.x - unit(0.045), y: centre.y))
                path.addLine(to: CGPoint(x: centre.x + unit(0.045), y: centre.y))
                context.stroke(path, with: .color(ink), style: line())
            }
        default:
            // Tall ovals.
            for x in [eyeLeft, eyeRight] {
                let centre = at(x, eyeY)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - unit(0.032), y: centre.y - unit(0.06),
                                                    width: unit(0.064), height: unit(0.12))), with: .color(ink))
            }
        }
    }

    private func drawMouth(_ context: GraphicsContext, ink: Color, blush: Color,
                           unit: (CGFloat) -> CGFloat, at: (CGFloat, CGFloat) -> CGPoint,
                           line: (CGFloat) -> StrokeStyle) {
        func arc(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                 _ start: Double, _ end: Double, filled: Bool = false) {
            let centre = at(x, y)
            var path = Path()
            path.addArc(center: centre, radius: unit(min(width, height)) / 2,
                        startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            if filled {
                // Closed along the diameter, so it fills as a half disc and
                // not as a slice.
                path.closeSubpath()
                context.fill(path, with: .color(ink))
            } else {
                context.stroke(path, with: .color(ink), style: line())
            }
        }
        switch ((avatar.mouth % KodaAvatar.mouthCount) + KodaAvatar.mouthCount) % KodaAvatar.mouthCount {
        case 0:
            arc(0.50, mouthY - 0.005, 0.16, 0.11, 20, 160)
        case 1:
            // Open and happy: a filled half.
            arc(0.50, mouthY - 0.0, 0.18, 0.15, 0, 180, filled: true)
        case 2:
            // The cat's ":3": two small bowls meeting in the middle.
            arc(0.46, mouthY - 0.0, 0.08, 0.07, 0, 180)
            arc(0.54, mouthY - 0.0, 0.08, 0.07, 0, 180)
        case 3:
            var path = Path()
            path.move(to: at(0.45, mouthY + 0.01))
            path.addLine(to: at(0.55, mouthY + 0.01))
            context.stroke(path, with: .color(ink), style: line())
        case 4:
            let centre = at(0.5, mouthY + 0.01)
            let circle = Path(ellipseIn: CGRect(x: centre.x - unit(0.035), y: centre.y - unit(0.035),
                                                width: unit(0.07), height: unit(0.07)))
            context.stroke(circle, with: .color(ink), style: line(0.03))
        default:
            // A grin with the tongue out.
            arc(0.50, mouthY - 0.005, 0.16, 0.11, 20, 160)
            let centre = at(0.53, mouthY + 0.055)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - unit(0.032), y: centre.y - unit(0.032),
                                                width: unit(0.064), height: unit(0.064))), with: .color(blush))
        }
    }

    // MARK: Extras

    private func drawExtraBehind(_ context: GraphicsContext, ink: Color, blush: Color,
                                 unit: (CGFloat) -> CGFloat, at: (CGFloat, CGFloat) -> CGPoint,
                                 line: (CGFloat) -> StrokeStyle) {
        switch ((avatar.extra % KodaAvatar.extraCount) + KodaAvatar.extraCount) % KodaAvatar.extraCount {
        case 1:
            // Headphones: a band over the top and a cup at each ear.
            var band = Path()
            band.addArc(center: at(0.5, 0.46), radius: unit(0.28),
                        startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(band, with: .color(ink), style: line(0.045))
            for x in [CGFloat(0.16), CGFloat(0.74)] {
                let origin = at(x, 0.40)
                context.fill(Path(roundedRect: CGRect(x: origin.x, y: origin.y,
                                                      width: unit(0.10), height: unit(0.17)),
                                  cornerRadius: unit(0.04)), with: .color(blush))
            }
        case 3:
            // A sprout: a stem and two leaves.
            var stem = Path()
            stem.move(to: at(0.5, 0.30))
            stem.addLine(to: at(0.5, 0.20))
            context.stroke(stem, with: .color(ink), style: line(0.03))
            for x in [CGFloat(0.41), CGFloat(0.50)] {
                let origin = at(x, 0.155)
                context.fill(Path(ellipseIn: CGRect(x: origin.x, y: origin.y,
                                                    width: unit(0.09), height: unit(0.055))), with: .color(blush))
            }
        case 4:
            // A bow: two wings and a knot.
            var bow = Path()
            bow.move(to: at(0.5, 0.235))
            bow.addLine(to: at(0.38, 0.175))
            bow.addLine(to: at(0.38, 0.295))
            bow.closeSubpath()
            bow.move(to: at(0.5, 0.235))
            bow.addLine(to: at(0.62, 0.175))
            bow.addLine(to: at(0.62, 0.295))
            bow.closeSubpath()
            context.fill(bow, with: .color(blush))
            let knot = at(0.5, 0.235)
            context.fill(Path(ellipseIn: CGRect(x: knot.x - unit(0.025), y: knot.y - unit(0.025),
                                                width: unit(0.05), height: unit(0.05))), with: .color(ink))
        default:
            break
        }
    }

    private func drawExtraFront(_ context: GraphicsContext, ink: Color, blush: Color,
                                unit: (CGFloat) -> CGFloat, at: (CGFloat, CGFloat) -> CGPoint,
                                line: (CGFloat) -> StrokeStyle) {
        switch ((avatar.extra % KodaAvatar.extraCount) + KodaAvatar.extraCount) % KodaAvatar.extraCount {
        case 2:
            // A sparkle: a four-point star up and to the side.
            let centre = at(0.74, 0.27)
            let long = unit(0.075)
            let short = unit(0.022)
            var star = Path()
            star.move(to: CGPoint(x: centre.x, y: centre.y - long))
            star.addLine(to: CGPoint(x: centre.x + short, y: centre.y - short))
            star.addLine(to: CGPoint(x: centre.x + long, y: centre.y))
            star.addLine(to: CGPoint(x: centre.x + short, y: centre.y + short))
            star.addLine(to: CGPoint(x: centre.x, y: centre.y + long))
            star.addLine(to: CGPoint(x: centre.x - short, y: centre.y + short))
            star.addLine(to: CGPoint(x: centre.x - long, y: centre.y))
            star.addLine(to: CGPoint(x: centre.x - short, y: centre.y - short))
            star.closeSubpath()
            context.fill(star, with: .color(blush))
        case 5:
            // Round glasses.
            for x in [eyeLeft, eyeRight] {
                let centre = at(x, eyeY)
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - unit(0.085), y: centre.y - unit(0.085),
                                                      width: unit(0.17), height: unit(0.17))),
                               with: .color(ink), style: line(0.025))
            }
            var bridge = Path()
            bridge.move(to: at(eyeLeft + 0.085, eyeY))
            bridge.addLine(to: at(eyeRight - 0.085, eyeY))
            context.stroke(bridge, with: .color(ink), style: line(0.025))
        default:
            break
        }
    }
}

/// The outline an avatar is cut to, by its stored index. It wraps, so an
/// unknown index still draws.
struct KodaAvatarOutline: Shape {
    let kind: Int

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        switch ((kind % KodaAvatar.shapeCount) + KodaAvatar.shapeCount) % KodaAvatar.shapeCount {
        case 0:
            return Path(ellipseIn: rect)
        case 1:
            return polygon(centre: centre, radius: radius, sides: 9, rotation: -.pi / 2)
        case 2:
            return flower(centre: centre, radius: radius, petals: 6)
        case 3:
            return polygon(centre: centre, radius: radius, sides: 6, rotation: -.pi / 2)
        case 4:
            return clover(centre: centre, radius: radius)
        case 5:
            return polygon(centre: centre, radius: radius, sides: 12, rotation: -.pi / 2)
        case 6:
            return burst(centre: centre, radius: radius, points: 12)
        case 7:
            return polygon(centre: centre, radius: radius, sides: 4, rotation: -.pi / 4)
        default:
            return sun(centre: centre, radius: radius, points: 12)
        }
    }

    private func polygon(centre: CGPoint, radius: CGFloat, sides: Int, rotation: CGFloat) -> Path {
        var path = Path()
        for index in 0..<sides {
            let angle = rotation + CGFloat(index) * 2 * .pi / CGFloat(sides)
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func flower(centre: CGPoint, radius: CGFloat, petals: Int) -> Path {
        var path = Path()
        let step = 2 * .pi / CGFloat(petals)
        for index in 0..<petals {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * step
            let tip = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            let left = angle + step * 0.28
            let right = angle - step * 0.28
            let leftPoint = CGPoint(x: centre.x + cos(left) * radius * 0.52, y: centre.y + sin(left) * radius * 0.52)
            let rightPoint = CGPoint(x: centre.x + cos(right) * radius * 0.52, y: centre.y + sin(right) * radius * 0.52)
            if index == 0 { path.move(to: tip) } else { path.addLine(to: tip) }
            path.addQuadCurve(to: leftPoint, control: CGPoint(x: centre.x + cos(angle - step * 0.1) * radius * 0.9,
                                                              y: centre.y + sin(angle - step * 0.1) * radius * 0.9))
            path.addQuadCurve(to: tip, control: leftPoint)
            path.addQuadCurve(to: rightPoint, control: CGPoint(x: centre.x + cos(angle + step * 0.1) * radius * 0.9,
                                                               y: centre.y + sin(angle + step * 0.1) * radius * 0.9))
            path.addQuadCurve(to: tip, control: rightPoint)
        }
        path.closeSubpath()
        return path
    }

    private func clover(centre: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for index in 0..<4 {
            let angle = CGFloat(index) * .pi / 2
            let lobe = CGPoint(x: centre.x + cos(angle) * radius * 0.42, y: centre.y + sin(angle) * radius * 0.42)
            path.addEllipse(in: CGRect(x: lobe.x - radius * 0.58, y: lobe.y - radius * 0.58,
                                       width: radius * 1.16, height: radius * 1.16))
        }
        return path
    }

    private func burst(centre: CGPoint, radius: CGFloat, points: Int) -> Path {
        var path = Path()
        let inner = radius * 0.78
        for index in 0..<(points * 2) {
            let angle = CGFloat(index) * .pi / CGFloat(points)
            let length = index.isMultiple(of: 2) ? radius : inner
            let point = CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func sun(centre: CGPoint, radius: CGFloat, points: Int) -> Path {
        var path = Path()
        let step = 2 * .pi / CGFloat(points)
        for index in 0..<points {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * step
            let next = angle + step / 2
            let tip = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            let middle = CGPoint(x: centre.x + cos(next) * radius * 0.82, y: centre.y + sin(next) * radius * 0.82)
            if index == 0 { path.move(to: tip) } else { path.addLine(to: tip) }
            path.addQuadCurve(to: middle, control: CGPoint(x: centre.x + cos(angle + step * 0.25) * radius * 0.98,
                                                            y: centre.y + sin(angle + step * 0.25) * radius * 0.98))
        }
        path.closeSubpath()
        return path
    }
}

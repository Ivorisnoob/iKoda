import SwiftUI

/// How large Koda draws its text on the Mac: View → Zoom In / Zoom Out / Actual Size (⌘+ ⌘− ⌘0)
/// and Settings → Appearance → Interface Size, as Safari and Notes let you zoom.
///
/// macOS has no Dynamic Type for apps (SwiftUI's text styles and `dynamicTypeSize` stay at their
/// Mac sizes whatever is set), so Koda keeps its own. Text goes through `Font.scaled(_:)` and
/// `Font.scaledSystem(size:weight:design:)`, which read `factor`; Observation then redraws every
/// view whose text read it. On the iPhone both give the system's own fonts and Dynamic Type
/// scales them as before. The sidebar follows the system's Sidebar icon size instead, as the
/// Mac's own sidebars do.
@MainActor
@Observable
final class InterfaceScale {
    static let shared = InterfaceScale()

    /// The sizes offered, as Safari's zoom steps are: from a little smaller to half again as big.
    static let steps: [Double] = [0.85, 0.92, 1, 1.08, 1.17, 1.25, 1.35, 1.5]

    private static let key = "koda.mac.interfaceScale"

    var factor: Double {
        didSet { UserDefaults.standard.set(factor, forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        factor = Self.steps.contains(saved) ? saved : 1
    }

    var canZoomIn: Bool { factor < Self.steps.last! }
    var canZoomOut: Bool { factor > Self.steps.first! }

    func zoomIn() {
        if let next = Self.steps.first(where: { $0 > factor }) { factor = next }
    }

    func zoomOut() {
        if let next = Self.steps.last(where: { $0 < factor }) { factor = next }
    }

    func reset() { factor = 1 }

    /// The point size of a text style on the Mac at Actual Size (Apple's macOS type sizes).
    nonisolated static func macSize(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }
}

extension CGFloat {
    /// A measurement grown or shrunk with Koda's Interface Size on the Mac, so covers, cards and
    /// rows zoom with their text; unchanged elsewhere.
    @MainActor
    var scaled: CGFloat {
        #if os(macOS)
        self * InterfaceScale.shared.factor
        #else
        self
        #endif
    }
}

extension Font {
    /// A text style, at Koda's Interface Size on the Mac; the system's own style elsewhere.
    @MainActor
    static func scaled(_ style: Font.TextStyle) -> Font {
        #if os(macOS)
        let size = InterfaceScale.macSize(of: style) * InterfaceScale.shared.factor
        // The Mac's headline is its body size in bold.
        return .system(size: size, weight: style == .headline ? .bold : .regular)
        #else
        return .system(style)
        #endif
    }

    /// A fixed point size, grown or shrunk with Koda's Interface Size on the Mac.
    @MainActor
    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if os(macOS)
        .system(size: size * InterfaceScale.shared.factor, weight: weight, design: design)
        #else
        .system(size: size, weight: weight, design: design)
        #endif
    }
}

/// Zoom In, Zoom Out and Actual Size, in the View menu.
struct InterfaceScaleCommands: Commands {
    var scale = InterfaceScale.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Actual Size") { scale.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(scale.factor == 1)
            Button("Zoom In") { scale.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!scale.canZoomIn)
            Button("Zoom Out") { scale.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!scale.canZoomOut)
        }
    }
}

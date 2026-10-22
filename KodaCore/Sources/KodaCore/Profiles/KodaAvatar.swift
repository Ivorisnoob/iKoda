import Foundation

/// One of Koda's own drawn avatars: a shape, a colour and a face, each chosen
/// from a small set, so a profile with no account and no photo still has a
/// picture that is recognisably its own.
///
/// It is a handful of indices rather than an image, so it costs nothing to
/// store, scales to any size, and a new option is a new number rather than a
/// new asset. The indices are stored, and match Koda for Android's: an option
/// may be added to the end of a set, never inserted or removed. An index past
/// the end of its set wraps when drawn, so an avatar made by a newer build
/// still draws.
public struct KodaAvatar: Codable, Hashable, Sendable {
    public var shape: Int
    public var color: Int
    public var eyes: Int
    public var mouth: Int
    public var extra: Int
    public var blush: Bool

    public static let shapes = 9
    public static var colors: Int { colorways.count }
    public static let eyeStyles = 6
    public static let mouths = 6
    public static let extras = 6

    public init(shape: Int = 0, color: Int = 0, eyes: Int = 0, mouth: Int = 0, extra: Int = 0, blush: Bool = false) {
        self.shape = shape
        self.color = color
        self.eyes = eyes
        self.mouth = mouth
        self.extra = extra
        self.blush = blush
    }

    // Each index wrapped into its set, for drawing and for marking the chosen option.
    public var shapeIndex: Int { Self.wrap(shape, Self.shapes) }
    public var colorIndex: Int { Self.wrap(color, Self.colors) }
    public var eyesIndex: Int { Self.wrap(eyes, Self.eyeStyles) }
    public var mouthIndex: Int { Self.wrap(mouth, Self.mouths) }
    public var extraIndex: Int { Self.wrap(extra, Self.extras) }

    public var colorway: Colorway { Self.colorways[colorIndex] }

    static func wrap(_ index: Int, _ count: Int) -> Int {
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }

    public static func random<R: RandomNumberGenerator>(using generator: inout R) -> KodaAvatar {
        // Drawn with plain modulo rather than `Int.random(in:using:)`, whose
        // algorithm the standard library does not promise to keep; a seeded
        // avatar has to come out the same on every platform and Swift version.
        func pick(_ count: Int) -> Int { Int(generator.next() % UInt64(count)) }
        return KodaAvatar(
            shape: pick(shapes),
            color: pick(colors),
            eyes: pick(eyeStyles),
            mouth: pick(mouths),
            extra: pick(extras),
            blush: generator.next() >> 63 == 1
        )
    }

    public static func random() -> KodaAvatar {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// The avatar a profile wears before anyone has chosen one: the same for
    /// the same seed (a profile id) on every launch and every device.
    /// `hashValue` is randomised per process, so the seed goes through FNV-1a.
    public static func seeded(_ seed: String) -> KodaAvatar {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var generator = SplitMix64(state: hash)
        return random(using: &generator)
    }

    // An avatar saved by an older build, or by a newer one with fewer keys,
    // still loads: anything missing takes its default.
    private enum CodingKeys: String, CodingKey {
        case shape, color, eyes, mouth, extra, blush
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(Int.self, forKey: .shape) ?? 0
        color = try container.decodeIfPresent(Int.self, forKey: .color) ?? 0
        eyes = try container.decodeIfPresent(Int.self, forKey: .eyes) ?? 0
        mouth = try container.decodeIfPresent(Int.self, forKey: .mouth) ?? 0
        extra = try container.decodeIfPresent(Int.self, forKey: .extra) ?? 0
        blush = try container.decodeIfPresent(Bool.self, forKey: .blush) ?? false
    }
}

extension KodaAvatar {
    /// A colour as sRGB components, 0…1.
    public struct RGB: Hashable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xff) / 255
            green = Double((hex >> 8) & 0xff) / 255
            blue = Double(hex & 0xff) / 255
        }
    }

    /// One colourway: the fill, the ink the face is drawn in, and the cheeks.
    public struct Colorway: Hashable, Sendable {
        public let name: String
        public let fill: RGB
        public let ink: RGB
        public let blush: RGB
    }

    /// The colourways, the same list as Koda for Android's.
    ///
    /// Literal colours on purpose: an avatar is somebody's picture, so it is
    /// the same peach face in light mode, dark mode and under an album's
    /// colours. Appended to, never reordered: the index is stored.
    public static let colorways: [Colorway] = [
        Colorway(name: "Peach", fill: RGB(0xFFD8C2), ink: RGB(0x5A2E1F), blush: RGB(0xFF8A65)),
        Colorway(name: "Mint", fill: RGB(0xC8F2DC), ink: RGB(0x1F4D3A), blush: RGB(0x5CCB95)),
        Colorway(name: "Lilac", fill: RGB(0xE3D4FF), ink: RGB(0x3B2A66), blush: RGB(0xA98BFF)),
        Colorway(name: "Sky", fill: RGB(0xCFE8FF), ink: RGB(0x1D3C5C), blush: RGB(0x6FB3F2)),
        Colorway(name: "Butter", fill: RGB(0xFFF0B8), ink: RGB(0x5C4A12), blush: RGB(0xF2B63C)),
        Colorway(name: "Rose", fill: RGB(0xFFD3E0), ink: RGB(0x5E2238), blush: RGB(0xFF7FA5)),
        Colorway(name: "Teal", fill: RGB(0xBFEDEA), ink: RGB(0x12474A), blush: RGB(0x45C1BC)),
        Colorway(name: "Coral", fill: RGB(0xFFC9C2), ink: RGB(0x5C211B), blush: RGB(0xFF7961)),
        Colorway(name: "Moss", fill: RGB(0xDDEBC0), ink: RGB(0x34451A), blush: RGB(0x9BC253)),
        Colorway(name: "Sand", fill: RGB(0xF0E2CF), ink: RGB(0x4A3B2A), blush: RGB(0xD9A066)),
        Colorway(name: "Dusk", fill: RGB(0x2E2A3D), ink: RGB(0xF3EEFF), blush: RGB(0x8E7CC3)),
        Colorway(name: "Night", fill: RGB(0x1F2A44), ink: RGB(0xE8F0FF), blush: RGB(0x5B8DEF)),
    ]
}

/// A small, fast generator with a fixed algorithm, so the same seed gives the
/// same numbers everywhere.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

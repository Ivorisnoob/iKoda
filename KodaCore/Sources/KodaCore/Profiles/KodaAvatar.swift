import Foundation

/// One of Koda's own drawn avatars: a shape, a colour and a face, each chosen
/// from a small set, so a profile with no account and no photo still has a
/// picture that is recognisably its own.
///
/// It is a handful of indices rather than an image, so it costs nothing to
/// store, scales to any size, and a new option is a new number rather than a
/// new asset. Indices are stored: an option may be added to the end of a set,
/// never inserted or removed. An index past the end of its set wraps, so a
/// profile restored from a newer build still draws.
public struct KodaAvatar: Hashable, Codable, Sendable {
    public var shape: Int
    public var color: Int
    public var eyes: Int
    public var mouth: Int
    public var extra: Int
    public var blush: Bool

    public static let shapeCount = 9
    public static let eyeCount = 6
    public static let mouthCount = 6
    public static let extraCount = 6

    public init(shape: Int, color: Int, eyes: Int, mouth: Int, extra: Int, blush: Bool) {
        self.shape = shape
        self.color = color
        self.eyes = eyes
        self.mouth = mouth
        self.extra = extra
        self.blush = blush
    }

    /// The six indices as one string, the way they are stored.
    public var encoded: String {
        "\(shape).\(color).\(eyes).\(mouth).\(extra).\(blush ? 1 : 0)"
    }

    /// An avatar read back from its string; nil when it is not one.
    public static func decode(_ text: String?) -> KodaAvatar? {
        guard let text else { return nil }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return KodaAvatar(shape: parts[0], color: parts[1], eyes: parts[2],
                          mouth: parts[3], extra: parts[4], blush: parts[5] == 1)
    }

    /// The avatar a profile wears before anyone has chosen one: the same
    /// every time for the same id.
    public static func forSeed(_ seed: String) -> KodaAvatar {
        random(seed: KodaAvatar.hash(seed))
    }

    /// An avatar drawn from a seed, the same way every time.
    public static func random(seed: UInt64) -> KodaAvatar {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Int(z % UInt64(bound))
        }
        return KodaAvatar(shape: next(shapeCount), color: next(KodaAvatarColours.all.count),
                          eyes: next(eyeCount), mouth: next(mouthCount), extra: next(extraCount),
                          blush: next(2) == 1)
    }

    /// A stable hash of a string: the same text always gives the same
    /// avatar, on every device and every launch.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }
}

/// One avatar colourway: the fill, the ink the face is drawn in, and the
/// cheeks.
///
/// These are literal colours on purpose: an avatar is somebody's picture, and
/// it has to be the same peach face in the dark theme, in the light one and
/// under an album's palette — a role from the colour scheme is by definition
/// none of those. Appended to, never reordered: the index is stored.
public struct KodaAvatarColour: Hashable, Codable, Sendable {
    /// 0xRRGGBB.
    public var fill: UInt32
    public var ink: UInt32
    public var blush: UInt32

    public init(fill: UInt32, ink: UInt32, blush: UInt32) {
        self.fill = fill
        self.ink = ink
        self.blush = blush
    }
}

/// The avatar colourways.
public enum KodaAvatarColours {
    public static let all: [KodaAvatarColour] = [
        KodaAvatarColour(fill: 0xFFD8C2, ink: 0x5A2E1F, blush: 0xFF8A65), // peach
        KodaAvatarColour(fill: 0xC8F2DC, ink: 0x1F4D3A, blush: 0x5CCB95), // mint
        KodaAvatarColour(fill: 0xE3D4FF, ink: 0x3B2A66, blush: 0xA98BFF), // lilac
        KodaAvatarColour(fill: 0xCFE8FF, ink: 0x1D3C5C, blush: 0x6FB3F2), // sky
        KodaAvatarColour(fill: 0xFFF0B8, ink: 0x5C4A12, blush: 0xF2B63C), // butter
        KodaAvatarColour(fill: 0xFFD3E0, ink: 0x5E2238, blush: 0xFF7FA5), // rose
        KodaAvatarColour(fill: 0xBFEDEA, ink: 0x12474A, blush: 0x45C1BC), // teal
        KodaAvatarColour(fill: 0xFFC9C2, ink: 0x5C211B, blush: 0xFF7961), // coral
        KodaAvatarColour(fill: 0xDDEBC0, ink: 0x34451A, blush: 0x9BC253), // moss
        KodaAvatarColour(fill: 0xF0E2CF, ink: 0x4A3B2A, blush: 0xD9A066), // sand
        KodaAvatarColour(fill: 0x2E2A3D, ink: 0xF3EEFF, blush: 0x8E7CC3), // dusk
        KodaAvatarColour(fill: 0x1F2A44, ink: 0xE8F0FF, blush: 0x5B8DEF), // night
    ]

    /// The colourway an avatar index names, wrapping so an unknown index still draws.
    public static func colour(_ index: Int) -> KodaAvatarColour {
        all[((index % all.count) + all.count) % all.count]
    }
}

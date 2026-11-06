import Foundation

/// The equalizer's presets, as Music's Settings → EQ lists them: each a curve over ten bands
/// an octave apart, from 32 Hz to 16 kHz.
public enum EqualizerPreset: String, CaseIterable, Identifiable, Sendable {
    case off, acoustic, bassBooster, bassReducer, classical, dance, deep, electronic, hipHop, jazz, latin,
         loudness, lounge, piano, pop, rnb, rock, smallSpeakers, spokenWord, trebleBooster, trebleReducer, vocalBooster

    public var id: Self { self }

    public var title: String {
        switch self {
        case .off: "Off"
        case .acoustic: "Acoustic"
        case .bassBooster: "Bass Booster"
        case .bassReducer: "Bass Reducer"
        case .classical: "Classical"
        case .dance: "Dance"
        case .deep: "Deep"
        case .electronic: "Electronic"
        case .hipHop: "Hip-Hop"
        case .jazz: "Jazz"
        case .latin: "Latin"
        case .loudness: "Loudness"
        case .lounge: "Lounge"
        case .piano: "Piano"
        case .pop: "Pop"
        case .rnb: "R&B"
        case .rock: "Rock"
        case .smallSpeakers: "Small Speakers"
        case .spokenWord: "Spoken Word"
        case .trebleBooster: "Treble Booster"
        case .trebleReducer: "Treble Reducer"
        case .vocalBooster: "Vocal Booster"
        }
    }

    /// Decibels for each of `Equalizer.frequencies`.
    public var gains: [Float] {
        switch self {
        case .off: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .acoustic: [4.5, 4.5, 3.5, 1, 1.5, 1.5, 3, 3.5, 3, 1.5]
        case .bassBooster: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]
        case .bassReducer: [-5.5, -4.5, -3.5, -2.5, -1, 0, 0, 0, 0, 0]
        case .classical: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]
        case .dance: [3.5, 6, 4.5, 0, 1.5, 3, 4.5, 4, 3, 0]
        case .deep: [4.5, 3.5, 1.5, 1, 3, 2.5, 1.5, -2, -3.5, -4.5]
        case .electronic: [4, 3.5, 1, 0, -2, 2, 1, 1.5, 4, 4.5]
        case .hipHop: [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]
        case .jazz: [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]
        case .latin: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]
        case .loudness: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]
        case .lounge: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]
        case .piano: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]
        case .pop: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]
        case .rnb: [2.5, 6.5, 5, 1.5, -2.5, -1.5, 2.5, 3, 3, 3.5]
        case .rock: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]
        case .smallSpeakers: [5.5, 4, 3.5, 2.5, 1, 0, -1, -2, -3, -4]
        case .spokenWord: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4, 2.5, 0]
        case .trebleBooster: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]
        case .trebleReducer: [0, 0, 0, 0, 0, -1, -2.5, -3.5, -4.5, -5.5]
        case .vocalBooster: [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5]
        }
    }
}

/// The filters behind a preset: a low shelf, eight peaks an octave wide and a high shelf, and a
/// level cut so the curve's loudest point never pushes a loud master past full scale.
nonisolated enum Equalizer {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    struct Design {
        var sections: [Biquad.Coefficients]
        /// Linear gain applied after the sections.
        var preamp: Float
    }

    /// Nil when the curve is flat: the song passes untouched.
    static func design(_ gains: [Float], sampleRate: Double) -> Design? {
        var sections: [Biquad.Coefficients] = []
        for (index, gain) in gains.prefix(frequencies.count).enumerated() where abs(gain) >= 0.05 {
            let frequency = frequencies[index]
            if index == 0 {
                sections.append(.lowShelf(frequency, gain: gain, sampleRate: sampleRate))
            } else if index == frequencies.count - 1 {
                sections.append(.highShelf(frequency, gain: gain, sampleRate: sampleRate))
            } else {
                sections.append(.peak(frequency, gain: gain, sampleRate: sampleRate))
            }
        }
        guard !sections.isEmpty else { return nil }
        let peak = peakResponse(sections, sampleRate: sampleRate)
        return Design(sections: sections, preamp: pow(10, -max(0, peak) / 20))
    }

    /// The curve's highest point in decibels, over the audible range.
    static func peakResponse(_ sections: [Biquad.Coefficients], sampleRate: Double) -> Float {
        let top = min(20_000, sampleRate * 0.49)
        var peak = -Float.infinity
        for step in 0...240 {
            let frequency = 20 * pow(top / 20, Double(step) / 240)
            peak = max(peak, response(sections, at: frequency, sampleRate: sampleRate))
        }
        return peak
    }

    /// The sections' combined gain in decibels at one frequency.
    static func response(_ sections: [Biquad.Coefficients], at frequency: Double, sampleRate: Double) -> Float {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), -sin(w), cos(2 * w), -sin(2 * w))
        var magnitude = 1.0
        for c in sections {
            let numRe = Double(c.b0) + Double(c.b1) * c1 + Double(c.b2) * c2
            let numIm = Double(c.b1) * s1 + Double(c.b2) * s2
            let denRe = 1 + Double(c.a1) * c1 + Double(c.a2) * c2
            let denIm = Double(c.a1) * s1 + Double(c.a2) * s2
            magnitude *= ((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)).squareRoot()
        }
        return Float(20 * log10(magnitude))
    }
}

/// The Audio EQ Cookbook's peaking and shelving sections.
extension Biquad.Coefficients {
    /// A bell an octave wide.
    static func peak(_ frequency: Float, gain: Float, sampleRate: Double) -> Self {
        let (a, cosw, sinw) = terms(frequency, gain, sampleRate)
        let alpha = sinw / (2 * 1.41)
        let a0 = 1 + alpha / a
        return Self(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0,
                    a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    static func lowShelf(_ frequency: Float, gain: Float, sampleRate: Double) -> Self {
        let (a, cosw, sinw) = terms(frequency, gain, sampleRate)
        let beta = 2 * a.squareRoot() * sinw / 2 * Float(2).squareRoot()
        let a0 = (a + 1) + (a - 1) * cosw + beta
        return Self(b0: a * ((a + 1) - (a - 1) * cosw + beta) / a0,
                    b1: 2 * a * ((a - 1) - (a + 1) * cosw) / a0,
                    b2: a * ((a + 1) - (a - 1) * cosw - beta) / a0,
                    a1: -2 * ((a - 1) + (a + 1) * cosw) / a0,
                    a2: ((a + 1) + (a - 1) * cosw - beta) / a0)
    }

    static func highShelf(_ frequency: Float, gain: Float, sampleRate: Double) -> Self {
        let (a, cosw, sinw) = terms(frequency, gain, sampleRate)
        let beta = 2 * a.squareRoot() * sinw / 2 * Float(2).squareRoot()
        let a0 = (a + 1) - (a - 1) * cosw + beta
        return Self(b0: a * ((a + 1) + (a - 1) * cosw + beta) / a0,
                    b1: -2 * a * ((a - 1) + (a + 1) * cosw) / a0,
                    b2: a * ((a + 1) + (a - 1) * cosw - beta) / a0,
                    a1: 2 * ((a - 1) - (a + 1) * cosw) / a0,
                    a2: ((a + 1) - (a - 1) * cosw - beta) / a0)
    }

    private static func terms(_ frequency: Float, _ gain: Float, _ sampleRate: Double) -> (Float, Float, Float) {
        let f = min(frequency, Float(sampleRate) * 0.45)
        let w = 2 * Float.pi * f / Float(sampleRate)
        return (pow(10, gain / 40), cos(w), sin(w))
    }
}

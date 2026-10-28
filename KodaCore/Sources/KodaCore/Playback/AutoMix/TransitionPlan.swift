import Foundation

/// Gain and filter moves over one song's own time, the way a mixer's faders and EQ move in
/// a DJ transition. Keyed to the song's time rather than the clock, so the moves land on the
/// music even if the main thread is late, and follow the song if it plays a little faster.
public nonisolated struct Automation: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: Double
        public var value: Float
    }

    /// Linear gain; 1 outside any points.
    public var gain: [Point] = []
    /// High-pass cutoff in Hz; off (`Automation.open`) outside any points.
    public var highPass: [Point] = []
    /// Low-pass cutoff in Hz; off outside any points.
    public var lowPass: [Point] = []

    /// A high-pass at or below this does nothing audible; the filter is skipped.
    public static let highPassOff: Float = 12
    /// A low-pass at or above this is skipped.
    public static let lowPassOff: Float = 19_000

    public var isEmpty: Bool { gain.isEmpty && highPass.isEmpty && lowPass.isEmpty }

    public func gain(at time: Double) -> Float { Self.value(gain, at: time, default: 1, logarithmic: false) }
    public func highPass(at time: Double) -> Float { Self.value(highPass, at: time, default: Self.highPassOff, logarithmic: true) }
    public func lowPass(at time: Double) -> Float { Self.value(lowPass, at: time, default: 20_000, logarithmic: true) }

    /// Between two points the value moves in a straight line; filter cutoffs move evenly in
    /// pitch (log frequency), as an ear hears a sweep.
    static func value(_ points: [Point], at time: Double, default fallback: Float, logarithmic: Bool) -> Float {
        guard let first = points.first, let last = points.last else { return fallback }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let f = Float((time - a.time) / max(1e-9, b.time - a.time))
        if logarithmic {
            return exp(log(max(1, a.value)) * (1 - f) + log(max(1, b.value)) * f)
        }
        return a.value + (b.value - a.value) * f
    }

    enum Shape {
        case linear
        /// Rises like the first quarter of a sine: quick at first, easing into the top.
        case sineIn
        /// Falls like a cosine quarter: holds near the top, then drops.
        case cosineOut
        /// Slow at both ends.
        case smooth
    }

    /// Points for a move from `v0` at `t0` to `v1` at `t1`.
    static func ramp(_ t0: Double, _ t1: Double, from v0: Float, to v1: Float, _ shape: Shape = .linear, steps: Int = 24) -> [Point] {
        guard t1 > t0 else { return [Point(time: t0, value: v1)] }
        let count = shape == .linear ? 1 : steps
        return (0...count).map { i in
            let x = Double(i) / Double(count)
            let y: Double = switch shape {
            case .linear: x
            case .sineIn: sin(x * .pi / 2)
            case .cosineOut: 1 - cos(x * .pi / 2)
            case .smooth: (1 - cos(x * .pi)) / 2
            }
            return Point(time: t0 + (t1 - t0) * x, value: v0 + (v1 - v0) * Float(y))
        }
    }
}

/// How one song hands over to the next: when the next starts, from where, how fast, and
/// what each song's gain and filters do meanwhile.
public nonisolated struct TransitionPlan: Sendable, Equatable {
    public enum Style: String, Sendable {
        /// Album tracks in order: no overlap, the next starts exactly as this one ends.
        case gapless
        /// Beats locked, bass handed from one song to the other mid-way.
        case beatMatch
        /// The song fades itself out; the next comes in under the fade.
        case fadeRide
        /// A ringing or quieter ending: the old song is filtered away as the next arrives.
        case filterBlend
        /// A hard ending with tempos that don't fit: a short overlap at the last note.
        case quickBlend
    }

    public var style: Style
    /// The outgoing song's time at which the next starts.
    public var cue: Double
    /// Where in the next song it starts.
    public var inStart: Double
    /// How long the two play together, in the outgoing song's seconds.
    public var overlap: Double
    /// The next song's playback rate while they overlap, matching its tempo to the outgoing one.
    public var rate: Double
    public var outgoing = Automation()
    public var incoming = Automation()
    public var reason: String
    /// With beats locked: an outgoing-song moment where both songs' beats land, and the beat period.
    public var firstBeat: Double?
    public var beatPeriod: Double?

    /// A moment of the overlap, in the outgoing song's time, as the incoming song's time.
    public func incomingTime(_ outgoingTime: Double) -> Double { inStart + (outgoingTime - cue) * rate }

    public var summary: String {
        "\(style.rawValue): cue \(cue.s2), next from \(inStart.s2), overlap \(overlap.s2) s, rate \(String(format: "%.4f", rate)) — \(reason)"
    }
}

/// Picks the transition for a pair of analysed songs.
public nonisolated enum TransitionPlanner {
    /// Onsets on the beat grid at least this much above average count as a pulse to mix on.
    public static let gridStrength = 1.5
    public static let tempoConfidence = 0.08
    /// Tempos further apart than this aren't stretched to meet; it would be heard.
    public static let maxStretch = 0.06
    /// A beat-matched blend lasts the most whole beats (32, 16 or 8) that fit this.
    public static let longestBlend = 12.0
    /// An early mix into an outro section may run longer.
    public static let earlyBlend = 18.0
    /// The most audible music (within 20 dB of the song's level) an early mix may leave out
    /// after it. Over 66 real songs, outros worth skipping left out 5.5 s at most; a soft final
    /// section only 4 to 12 dB under the song (WILDFLOWER's, Chemtrails' coda) left out 14.5 s
    /// and more. Beat strength doesn't tell them apart: Chemtrails' coda keeps a strong beat.
    public static let maxLeftOut = 8.0
    /// How long before a hard stop the next song comes in when the beats can't be locked.
    public static let hardStopBlend = 3.0

    public struct Context: Sendable {
        /// The outgoing song's playable end (YouTube's length).
        public var outgoingEnd: Double
        /// The two are neighbouring tracks of one album played in order.
        public var albumNeighbours: Bool

        public init(outgoingEnd: Double, albumNeighbours: Bool) {
            self.outgoingEnd = outgoingEnd
            self.albumNeighbours = albumNeighbours
        }
    }

    public static func plan(from a: TrackAnalysis, to b: TrackAnalysis, context: Context) -> TransitionPlan? {
        let end = min(a.musicEnd, context.outgoingEnd)
        guard context.outgoingEnd > 20 else { return nil }
        if context.albumNeighbours {
            return TransitionPlan(style: .gapless, cue: context.outgoingEnd, inStart: 0, overlap: 0, rate: 1,
                                  reason: "neighbouring album tracks keep their own gap")
        }
        // Past a long silent lead-in, but never far into a song.
        let entry = min(max(0, b.musicStart - 0.02), 20)
        let match = tempoMatch(a, b)
        let quietIntro = b.introLength >= 2.5

        // Like Music, look well back from the end for the best place to hand over, not only at it.
        let earliest = max(a.musicStart + 0.5 * (end - a.musicStart), end - searchWindow)
        var plan: TransitionPlan
        let quietTail = a.finalStretch(below: a.bodyDb - 10, notBefore: earliest)
        let outroSection = a.finalStretch(below: a.bodyDb - 4, notBefore: earliest)
        if let match, end - outroSection >= 8, outroSection < end - 12 || end - quietTail >= 12,
           let blend = beatMatch(a, b, end: end, match: match, from: outroSection),
           a.seconds(above: a.bodyDb - 20, from: blend.cue + blend.overlap, to: end) <= maxLeftOut {
            // Tempos fit and the song settles into a quieter outro: mix there, beats locked,
            // as a DJ would, leaving the rest of the outro out.
            return blend
        }
        if end - quietTail >= 12 {
            // A long stretch well under the song's level up to its end (a long quiet outro, a coda
            // near silence): little is lost by leaving it, so hand over where it begins.
            plan = outroBlend(a, b, from: quietTail, end: end, entry: entry, quietIntro: quietIntro)
        } else {
            plan = endingPlan(a, b, end: end, entry: entry, quietIntro: quietIntro, match: match)
        }
        // A pulse on both sides still gets its beats lined up and its tempo met, whatever the style.
        if plan.style == .beatMatch { return plan }
        if let match, let outro = a.grid(near: plan.cue), let intro = b.intro,
           outro.strength >= gridStrength, intro.strength >= gridStrength {
            plan = snap(plan, outro: outro, intro: intro, rate: match.rate, entryFrom: b.musicStart)
            plan.reason += "; beats lined up (\(outro.bpm.s1) → \(intro.bpm.s1) bpm, rate \(String(format: "%.3f", match.rate)))"
        } else if let match {
            plan.reason += "; tempos fit (rate \(String(format: "%.3f", match.rate))) but the pulse is too weak to line up"
        } else {
            plan.reason += "; tempos " + tempoNote(a, b)
        }
        return plan
    }

    /// How far back from the end a handover may start.
    public static let searchWindow = 150.0

    /// The handover at the song's own ending, by how it ends.
    static func endingPlan(_ a: TrackAnalysis, _ b: TrackAnalysis, end: Double, entry: Double, quietIntro: Bool, match: Match?) -> TransitionPlan {
        var plan: TransitionPlan
        switch a.ending {
        case .hard:
            if let match, let blend = beatMatch(a, b, end: end, match: match, from: nil) {
                return blend
            }
            plan = quickBlend(a, b, end: end, entry: entry, quietIntro: quietIntro)
        case .fade:
            plan = fadeRide(a, b, end: end, entry: entry, quietIntro: quietIntro)
        case .decay:
            if let match, a.outro.map({ $0.strength >= gridStrength * 1.2 }) == true,
               let blend = beatMatch(a, b, end: end, match: match, from: nil) {
                return blend
            }
            plan = filterBlend(a, b, end: end, entry: entry, quietIntro: quietIntro)
        }
        return plan
    }

    /// Leave a long quiet ending out: the next song starts a few seconds into it and the old
    /// one is faded away under it, well before its own end.
    static func outroBlend(_ a: TrackAnalysis, _ b: TrackAnalysis, from quiet: Double, end: Double, entry: Double, quietIntro: Bool) -> TransitionPlan {
        let cue = quiet + min(3, 0.1 * (end - quiet))
        let length = min(12, end - cue)
        var plan = TransitionPlan(style: .filterBlend, cue: cue, inStart: entry, overlap: length, rate: 1,
                                  reason: "the last \((end - quiet).s1) s sit well under the song's level; handing over \((end - cue).s1) s before the end"
                                    + (a.hiddenTail > 0 ? " (a hidden track after silence left out)" : ""))
        plan.outgoing.gain = [.init(time: cue, value: 1)] + Automation.ramp(cue + 0.3 * length, cue + length, from: 1, to: 0, .smooth)
        plan.outgoing.lowPass = Automation.ramp(cue + 0.3 * length, cue + length, from: 18_000, to: 1_200, .smooth)
        plan.incoming = entrance(plan, quietIntro: quietIntro, over: 0.6 * length)
        return plan
    }

    struct Match {
        var rate: Double
        /// The incoming beat period as heard at that rate, folded to the outgoing one's octave.
        var factor: Double
    }

    /// The rate that brings the incoming song's tempo onto the outgoing one's, allowing for
    /// one being heard at half or double the other, when it is within `maxStretch`.
    static func tempoMatch(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Match? {
        guard a.tempoConfidence >= tempoConfidence, b.tempoConfidence >= tempoConfidence,
              let outPeriod = a.outro?.period ?? a.bpm.map({ 60 / $0 }),
              let inPeriod = b.intro?.period ?? b.bpm.map({ 60 / $0 }) else { return nil }
        var best: Match?
        for factor in [0.5, 1, 2] {
            // The incoming beats come every inPeriod / factor when folded; matching them means
            // playing it at this rate.
            let rate = inPeriod / (factor * outPeriod)
            if abs(rate - 1) <= maxStretch, best.map({ abs(rate - 1) < abs($0.rate - 1) }) ?? true {
                best = Match(rate: rate, factor: factor)
            }
        }
        return best
    }

    static func tempoNote(_ a: TrackAnalysis, _ b: TrackAnalysis) -> String {
        guard let x = a.outro?.bpm ?? a.bpm, let y = b.intro?.bpm ?? b.bpm else { return "unknown" }
        return "\(x.s1) vs \(y.s1) bpm don't fit"
    }

    // MARK: Styles

    /// Locked beats over 8 to 32 beats ending on the outgoing song's last beat: the new song
    /// comes in without its bass, the bass changes hands half-way on a beat, then the old song
    /// leaves.
    ///
    /// With `section`, the blend instead starts on the beat where the song's outro section
    /// begins, however far before the end, and the rest of the outro is left out.
    static func beatMatch(_ a: TrackAnalysis, _ b: TrackAnalysis, end: Double, match: Match, from section: Double?) -> TransitionPlan? {
        guard let outro = section.map({ a.grid(near: $0 + 6) }) ?? a.outro, let intro = b.intro,
              outro.strength >= gridStrength, intro.strength >= gridStrength else { return nil }
        let p = outro.period
        let candidates: [Double] = [32, 16, 8]
        let cueBeat: Double
        let beats: Double
        if let section {
            cueBeat = outro.beat(atOrBefore: section + p / 2)
            guard let n = candidates.first(where: { n in n * p <= earlyBlend && cueBeat + n * p <= end }) else { return nil }
            beats = n
        } else {
            let lastBeat = outro.beat(atOrBefore: end - 0.15)
            let earliest = a.musicStart + 30
            guard let n = candidates.first(where: { n in n * p <= longestBlend && lastBeat - n * p > earliest }) else {
                return nil
            }
            beats = n
            cueBeat = lastBeat - beats * p
        }
        let inStart = min(max(0, b.musicStart - 0.02), 20)
        let inBeat = intro.beat(atOrAfter: inStart)
        // The next song starts at its first sound, early enough that its first beat lands on cueBeat.
        let lead = (inBeat - inStart) / match.rate
        let cue = cueBeat - lead
        let length = beats * p + lead
        let mid = cueBeat + beats / 2 * p
        let at = section.map { _ in "mixing at the outro section, \((end - cueBeat).s1) s before the end; " } ?? ""
        var plan = TransitionPlan(style: .beatMatch, cue: cue, inStart: inStart, overlap: length, rate: match.rate,
                                  reason: at + "\(Int(beats)) beats at \(outro.bpm.s1) bpm locked to \(intro.bpm.s1) bpm, bass swap at \(mid.s2)")
        plan.firstBeat = cueBeat
        plan.beatPeriod = p
        let blendEnd = cue + length
        // The outgoing song: full until the swap, then its bass goes over one beat, then it fades.
        plan.outgoing.gain = [.init(time: cue, value: 1), .init(time: mid, value: 1)]
            + Automation.ramp(mid, blendEnd, from: 1, to: 0, .cosineOut)
        plan.outgoing.highPass = [.init(time: mid - p / 2, value: Automation.highPassOff)]
            + Automation.ramp(mid - p / 2, mid + p / 2, from: Automation.highPassOff, to: 300, .smooth)
        // The incoming one: in under the old song without its bass, the bass arriving with the swap.
        let t = plan.incomingTime
        plan.incoming.gain = Automation.ramp(t(cue), t(cue + beats / 4 * p), from: 0, to: 0.6, .sineIn)
            + Automation.ramp(t(cue + beats / 4 * p), t(mid), from: 0.6, to: 0.85)
            + Automation.ramp(t(mid), t(mid + p), from: 0.85, to: 1, .smooth)
        plan.incoming.highPass = [.init(time: t(cue), value: 300)]
            + Automation.ramp(t(mid - p / 2), t(mid + p / 2), from: 300, to: Automation.highPassOff, .smooth)
        return plan
    }

    /// The outgoing song fades itself out, so its own fade is left to do the work: the next
    /// song comes in early, while the old one is still near full, rises gently under it, and
    /// only the last moments of the old fade are trimmed. Fading it again on top of its own
    /// fade made it drop away too fast.
    static func fadeRide(_ a: TrackAnalysis, _ b: TrackAnalysis, end: Double, entry: Double, quietIntro: Bool) -> TransitionPlan {
        let fadeStart = a.outroStart ?? end - 6
        // A quarter into the fade, within six to twelve seconds of the end.
        let cue = min(max(fadeStart + 0.25 * (end - fadeStart), end - fadeOverlap.upperBound), end - fadeOverlap.lowerBound)
        let length = end - cue
        var plan = TransitionPlan(style: .fadeRide, cue: cue, inStart: entry, overlap: length, rate: 1,
                                  reason: "outgoing fades out over \((end - fadeStart).s1) s; next enters \(length.s1) s before silence"
                                    + (quietIntro ? " with its quiet intro" : ""))
        plan.outgoing.gain = [.init(time: cue, value: 1)] + Automation.ramp(cue + 0.6 * length, end, from: 1, to: 0, .smooth)
        plan.incoming = entrance(plan, quietIntro: quietIntro, over: 0.7 * length)
        return plan
    }

    /// How long a ridden fade overlaps the next song, in seconds.
    static let fadeOverlap = 6.0...12.0

    /// A ring-out or a quieter outro: let it breathe a moment, then filter it away under the next.
    static func filterBlend(_ a: TrackAnalysis, _ b: TrackAnalysis, end: Double, entry: Double, quietIntro: Bool) -> TransitionPlan {
        let outro = a.outroStart ?? end - 4
        let cue = min(max(outro + 1.5, end - 8), end - 5)
        let length = end - cue
        var plan = TransitionPlan(style: .filterBlend, cue: cue, inStart: entry, overlap: length, rate: 1,
                                  reason: "outgoing rings out over \((end - outro).s1) s; filtered away over \(length.s1) s"
                                    + (quietIntro ? ", next's quiet intro at full level" : ""))
        plan.outgoing.gain = Automation.ramp(cue, end, from: 1, to: 0, .cosineOut)
        plan.outgoing.lowPass = Automation.ramp(cue, end, from: 18_000, to: 900, .smooth)
        plan.incoming = entrance(plan, quietIntro: quietIntro, over: 0.7 * length)
        return plan
    }

    /// A hard stop the next can't be beat-matched to: the next song comes in on one of the old
    /// song's beats a few seconds before the stop and takes the bass at once, while the old one
    /// loses its bass and fades under it, so two kicks at different tempos never run together.
    /// Starting the next on the old song's last moment, as before, sounded like a cut.
    static func quickBlend(_ a: TrackAnalysis, _ b: TrackAnalysis, end: Double, entry: Double, quietIntro: Bool) -> TransitionPlan {
        var cue = end - hardStopBlend
        if let grid = a.grid(near: cue), grid.strength >= gridStrength {
            cue = grid.beat(atOrBefore: cue + grid.period / 2)
        }
        cue = min(max(cue, end - 4.5), end - 1.5)
        let length = end - cue
        var plan = TransitionPlan(style: .quickBlend, cue: cue, inStart: entry, overlap: length, rate: 1,
                                  reason: "outgoing ends hard; next comes in on a beat \(length.s1) s before the stop")
        plan.outgoing.gain = [.init(time: cue, value: 1)] + Automation.ramp(cue + 0.3 * length, end, from: 1, to: 0, .cosineOut)
        plan.outgoing.highPass = Automation.ramp(cue, cue + 0.4 * length, from: Automation.highPassOff, to: 300, .smooth)
        // Full-on, the next song arrives with its bass: the old one has just handed it over.
        plan.incoming.gain = Automation.ramp(entry, entry + min(quietIntro ? 1.5 : 0.5 * length, length), from: 0, to: 1, .smooth)
        return plan
    }

    /// How the next song comes in when beats aren't locked: a quiet intro, which fades itself
    /// in, rises over a second and a half; a full-on start rises slowly at first over
    /// `seconds`, its bass following.
    static func entrance(_ plan: TransitionPlan, quietIntro: Bool, over seconds: Double) -> Automation {
        var automation = Automation()
        let start = plan.inStart
        if quietIntro {
            automation.gain = Automation.ramp(start, start + min(1.5, seconds), from: 0, to: 1, .smooth)
        } else {
            automation.gain = Automation.ramp(start, start + seconds, from: 0, to: 1, .smooth)
            automation.highPass = Automation.ramp(start, start + seconds, from: 160, to: Automation.highPassOff, .smooth)
        }
        return automation
    }

    /// Moves a plan's cue so the next song's first beat lands on one of the outgoing song's
    /// beats, playing it at `rate`. The next song still starts at its first sound: moving its
    /// start onto the beat cut off whatever came before it.
    static func snap(_ plan: TransitionPlan, outro: BeatGrid, intro: BeatGrid, rate: Double, entryFrom musicStart: Double) -> TransitionPlan {
        var snapped = plan
        let inBeat = intro.beat(atOrAfter: max(0, musicStart - 0.02))
        // Outgoing seconds from the cue until the next song reaches that beat.
        let lead = max(0, inBeat - plan.inStart) / rate
        let landing = outro.beat(atOrBefore: plan.cue + lead + outro.period / 2)
        snapped.cue = landing - lead
        snapped.rate = rate
        snapped.firstBeat = landing
        snapped.beatPeriod = outro.period
        snapped.outgoing = shifted(plan.outgoing, by: snapped.cue - plan.cue)
        return snapped
    }

    static func shifted(_ automation: Automation, by offset: Double) -> Automation {
        func move(_ points: [Automation.Point]) -> [Automation.Point] { points.map { .init(time: $0.time + offset, value: $0.value) } }
        return Automation(gain: move(automation.gain), highPass: move(automation.highPass), lowPass: move(automation.lowPass))
    }
}

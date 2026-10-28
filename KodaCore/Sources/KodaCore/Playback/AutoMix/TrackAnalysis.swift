import Accelerate
import Foundation

/// Where a song pulses: a beat period and one beat time, found within a stretch of the song
/// (its opening or its close) rather than across all of it, so a tempo that is slightly off
/// can't drift the grid away from the beats where a transition actually happens.
public nonisolated struct BeatGrid: Codable, Sendable, Equatable {
    /// Seconds per beat.
    public var period: Double
    /// A beat, in seconds into the song.
    public var anchor: Double
    /// How much stronger the onsets on the grid are than the stretch's average: about 1 for
    /// music with no pulse, 2 or more for a steady beat.
    public var strength: Double

    public var bpm: Double { 60 / period }

    /// The first beat at or after `time`.
    public func beat(atOrAfter time: Double) -> Double {
        anchor + (((time - anchor) / period).rounded(.up)) * period
    }

    /// The last beat at or before `time`.
    public func beat(atOrBefore time: Double) -> Double {
        anchor + (((time - anchor) / period).rounded(.down)) * period
    }
}

/// What AutoMix measured in one song's audio, kept per video id.
public nonisolated struct TrackAnalysis: Codable, Sendable, Equatable {
    /// Bumped whenever the measurements change meaning, so older results are measured again.
    public static let currentVersion = 3

    public enum Ending: String, Codable, Sendable {
        /// The song fades itself out over several seconds.
        case fade
        /// The music stops within a second or so.
        case hard
        /// Neither: a quieter outro, a held chord ringing out.
        case decay
    }

    public var version = TrackAnalysis.currentVersion
    public var duration: Double
    /// The first and last moments with sound, past leading and trailing silence.
    public var musicStart: Double
    public var musicEnd: Double
    /// The song's usual loud level, dBFS (75th percentile of short-term RMS).
    public var bodyDb: Double
    public var ending: Ending
    /// Where the song last plays near its usual level before its ending (fade or decay).
    public var outroStart: Double?
    /// Where a fade-out has come down 8 dB: a natural moment for the next song to start.
    public var fadeCue: Double?
    /// Where the song first reaches near its usual level; a long gap from `musicStart` is a quiet intro.
    public var introEnd: Double
    public var bpm: Double?
    /// How clearly the song keeps one tempo, roughly 0 (none) to 0.5 and up (a steady beat).
    public var tempoConfidence: Double
    public var intro: BeatGrid?
    public var outro: BeatGrid?
    /// Beat grids over overlapping 24-second stretches of the last two and a half minutes, so
    /// a transition can lock beats well before the end.
    public var grids: [BeatGrid] = []
    /// The level over the whole song, dB every `envelopeStep` seconds from the start.
    public var envelope: [Float] = []
    /// Seconds of sound left out after a long silence near the end (a hidden track): the
    /// song is treated as ending where the silence begins.
    public var hiddenTail: Double = 0

    public static let envelopeStep = 0.5

    public var introLength: Double { max(0, introEnd - musicStart) }

    /// The song's level around `time`.
    public func level(at time: Double) -> Double {
        guard !envelope.isEmpty else { return bodyDb }
        let i = min(envelope.count - 1, max(0, Int((time / Self.envelopeStep).rounded())))
        return Double(envelope[i])
    }

    /// Where the song's last stretch, up to `musicEnd`, quieter than `threshold` dB begins:
    /// louder moments shorter than `blip` don't end it. Never before `earliest`.
    public func finalStretch(below threshold: Double, notBefore earliest: Double, blip: Double = 1.5) -> Double {
        guard !envelope.isEmpty else { return musicEnd }
        var k = min(envelope.count - 1, Int(musicEnd / Self.envelopeStep) - 1)
        var start = musicEnd
        var loudRun = 0
        while k >= 0, Double(k) * Self.envelopeStep >= earliest {
            if Double(envelope[k]) > threshold {
                loudRun += 1
                if Double(loudRun) * Self.envelopeStep > blip { break }
            } else {
                loudRun = 0
                start = Double(k) * Self.envelopeStep
            }
            k -= 1
        }
        return max(start, earliest)
    }

    /// Seconds between `start` and `end` heard above `threshold` dB.
    public func seconds(above threshold: Double, from start: Double, to end: Double) -> Double {
        guard !envelope.isEmpty, end > start else { return 0 }
        let first = max(0, Int(start / Self.envelopeStep)), last = min(envelope.count, Int(end / Self.envelopeStep))
        guard first < last else { return 0 }
        return Double(envelope[first..<last].count(where: { Double($0) > threshold })) * Self.envelopeStep
    }

    /// The beat grid measured nearest `time`: the end grids, then the intro and outro ones.
    public func grid(near time: Double) -> BeatGrid? {
        let all = grids + [intro, outro].compactMap { $0 }
        return all.min { abs($0.anchor - time) < abs($1.anchor - time) }
    }

    public var summary: String {
        var parts = ["dur \(duration.s1)", "music \(musicStart.s2)-\(musicEnd.s2)", "body \(bodyDb.s1) dB",
                     "ending \(ending.rawValue)"]
        if hiddenTail > 0 { parts.append("left out \(hiddenTail.s1) s after a long silence") }
        if let outroStart { parts.append("outro from \(outroStart.s1)") }
        if let fadeCue { parts.append("fade -8dB at \(fadeCue.s1)") }
        parts.append("intro reaches body at \(introEnd.s1)")
        if let bpm { parts.append("bpm \(bpm.s1) conf \(tempoConfidence.s2)") } else { parts.append("no tempo (conf \(tempoConfidence.s2))") }
        if let intro { parts.append("intro grid \(intro.bpm.s1) bpm @\(intro.anchor.s2) str \(intro.strength.s2)") }
        if let outro { parts.append("outro grid \(outro.bpm.s1) bpm @\(outro.anchor.s2) str \(outro.strength.s2)") }
        if !grids.isEmpty {
            let strengths = grids.map { String(format: "%.1f", $0.strength) }.joined(separator: " ")
            parts.append("\(grids.count) end grids (str \(strengths))")
        }
        return parts.joined(separator: ", ")
    }
}

/// The measurements themselves, on mono samples. Pure functions, so tests can feed them
/// made-up signals.
public nonisolated enum TrackAnalyzer {
    /// The rate songs are decoded at for analysis: enough for loudness and onsets, half the work of 44.1 kHz.
    public static let sampleRate: Double = 22_050

    public static func analyze(_ samples: [Float], sampleRate: Double = sampleRate) -> TrackAnalysis {
        let duration = Double(samples.count) / sampleRate
        let levels = Levels(samples, sampleRate: sampleRate)
        let onsets = Onsets(samples, sampleRate: sampleRate)
        var analysis = TrackAnalysis(duration: duration, musicStart: levels.musicStart, musicEnd: levels.musicEnd,
                                     bodyDb: levels.bodyDb, ending: levels.ending, outroStart: levels.outroStart,
                                     fadeCue: levels.fadeCue, introEnd: levels.introEnd, bpm: nil, tempoConfidence: 0)
        analysis.envelope = levels.envelope
        analysis.hiddenTail = levels.hiddenTail
        guard levels.musicEnd - levels.musicStart > 20 else { return analysis }
        let tempo = onsets.tempo(from: levels.musicStart + 2, to: levels.musicEnd - 2)
        analysis.tempoConfidence = tempo.confidence
        guard let period = tempo.period else { return analysis }
        analysis.bpm = 60 / period
        // The grids are searched where transitions happen: the first and the last half minute of music.
        let introTo = min(levels.musicStart + 30, levels.musicEnd)
        analysis.intro = onsets.grid(from: levels.musicStart, to: introTo, near: period)
        let outroTo = levels.ending == .fade ? (levels.fadeCue ?? levels.musicEnd) : levels.musicEnd
        analysis.outro = onsets.grid(from: max(levels.musicStart, outroTo - 30), to: outroTo, near: period)
        // Further back, every 12 s, a narrower search around the outro's own tempo.
        let refined = analysis.outro?.period ?? period
        var windowEnd = levels.musicEnd
        let earliest = max(levels.musicStart, levels.musicEnd - 170)
        while windowEnd - 24 >= earliest {
            if let grid = onsets.grid(from: windowEnd - 24, to: windowEnd, near: refined, spread: 0.008) {
                analysis.grids.append(grid)
            }
            windowEnd -= 12
        }
        return analysis
    }

    // MARK: - Loudness over time

    struct Levels {
        var musicStart: Double = 0
        var musicEnd: Double = 0
        var bodyDb: Double = -100
        var ending: TrackAnalysis.Ending = .hard
        var outroStart: Double?
        var fadeCue: Double?
        var introEnd: Double = 0
        var envelope: [Float] = []
        var hiddenTail: Double = 0

        /// Short frames for finding where sound starts and stops.
        static let frame = 0.05
        /// A one-second moving window, every 0.1 s, for the shape of fades and intros.
        static let smoothHop = 0.1

        init(_ samples: [Float], sampleRate: Double) {
            let frameLength = Int(sampleRate * Self.frame)
            guard frameLength > 0, samples.count >= frameLength * 4 else { return }
            let frameCount = samples.count / frameLength
            var power = [Float](repeating: 0, count: frameCount)
            samples.withUnsafeBufferPointer { buffer in
                for i in 0..<frameCount {
                    var mean: Float = 0
                    vDSP_measqv(buffer.baseAddress! + i * frameLength, 1, &mean, vDSP_Length(frameLength))
                    power[i] = mean
                }
            }
            let db = power.map { Self.db($0) }
            func time(_ i: Int) -> Double { Double(i) * Self.frame }

            // A first pass with a fixed floor finds the music, the body level, then the real floor.
            let rough = Self.audibleRange(db, floor: -55) ?? 0..<frameCount
            var body = Self.percentile(Array(db[rough]).filter { $0 > -70 }, 0.75) ?? -20
            bodyDb = Double(body)
            let floor = min(-40, max(-60, body - 35))
            let range = Self.audibleRange(db, floor: floor) ?? rough
            musicStart = time(range.lowerBound)
            musicEnd = min(time(range.upperBound), Double(samples.count) / sampleRate)
            // A long silence in the second half (a hidden track after it) ends the song there.
            let gapFrames = Int(4 / Self.frame)
            let half = range.lowerBound + range.count / 2
            var run = 0
            var gapStart: Int?
            for j in half..<range.upperBound {
                if db[j] <= floor {
                    run += 1
                    if run == gapFrames { gapStart = j - run + 1 }
                } else {
                    run = 0
                }
            }
            if let gapStart, time(gapStart) < musicEnd {
                hiddenTail = musicEnd - time(gapStart)
                musicEnd = time(gapStart)
            }

            // The smoothed envelope: mean power over the second centred on each 0.1 s step.
            let perHop = Int((Self.smoothHop / Self.frame).rounded())
            let halfWindow = Int((0.5 / Self.frame).rounded())
            var smooth: [Float] = []
            var i = 0
            while i < frameCount {
                let lo = max(0, i - halfWindow), hi = min(frameCount, i + halfWindow)
                var sum: Float = 0
                for j in lo..<hi { sum += power[j] }
                smooth.append(Self.db(sum / Float(hi - lo)))
                i += perHop
            }
            func smoothTime(_ k: Int) -> Double { Double(k) * Self.smoothHop }
            let envelopeStride = Int((TrackAnalysis.envelopeStep / Self.smoothHop).rounded())
            envelope = stride(from: 0, to: smooth.count, by: envelopeStride).map { (smooth[$0] * 10).rounded() / 10 }
            let startK = Int(musicStart / Self.smoothHop), endK = min(smooth.count - 1, Int(musicEnd / Self.smoothHop))
            guard endK > startK + 20 else { introEnd = musicStart; return }
            // The usual level as heard, over seconds: short frames between the hits of a sparse
            // beat would put it at the quiet underneath.
            body = Self.percentile(Array(smooth[startK...endK]), 0.75) ?? body
            bodyDb = Double(body)

            introEnd = musicStart
            for k in startK...endK where smooth[k] >= body - 6 {
                introEnd = smoothTime(k)
                break
            }

            // The ending: from the end back to the last moment near the usual level.
            var lastLoud = endK
            while lastLoud > startK, smooth[lastLoud] < body - 3 { lastLoud -= 1 }
            let tailLength = musicEnd - smoothTime(lastLoud)
            if tailLength <= 1.6 {
                ending = .hard
                return
            }
            outroStart = smoothTime(lastLoud)
            // A fade keeps falling; a quieter outro or a held chord wanders or holds. Compared a
            // second apart, so the pulse of the beat inside the one-second window doesn't count.
            let secondApart = Int((1 / Self.smoothHop).rounded())
            var falling = 0, steps = 0
            var k = lastLoud
            while k + secondApart <= endK {
                steps += 1
                if smooth[k + secondApart] <= smooth[k] + 1 { falling += 1 }
                k += secondApart
            }
            let midpoint = min(endK, (lastLoud + endK) / 2)
            let fallsSteadily = steps >= 3 && Double(falling) / Double(steps) >= 0.75
            if tailLength >= 3.5, fallsSteadily, smooth[midpoint] <= body - 4 {
                ending = .fade
                for k in lastLoud...endK where smooth[k] <= body - 8 {
                    fadeCue = smoothTime(k)
                    break
                }
            } else {
                ending = .decay
            }
        }

        static func db(_ power: Float) -> Float { power > 1e-10 ? 10 * log10(power) : -100 }

        /// The frames between the first and the last with sound above `floor`, two in a row
        /// so a lone click isn't taken for music.
        static func audibleRange(_ db: [Float], floor: Float) -> Range<Int>? {
            guard db.count > 2 else { return nil }
            guard let first = (0..<(db.count - 1)).first(where: { db[$0] > floor && db[$0 + 1] > floor }),
                  let last = (1..<db.count).reversed().first(where: { db[$0] > floor && db[$0 - 1] > floor }),
                  last > first else { return nil }
            return first..<(last + 1)
        }

        static func percentile(_ values: [Float], _ p: Double) -> Float? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
    }

    // MARK: - Onsets, tempo and beat grids

    struct Onsets {
        /// Onset strength per hop: spectral flux, with the local average taken away.
        var values: [Float] = []
        let fps: Double
        /// The flux of a hop belongs to the moment its window's centre reaches, half a window in.
        let offset: Double

        static let hop = 256
        static let window = 1024

        init(_ samples: [Float], sampleRate: Double) {
            fps = sampleRate / Double(Self.hop)
            offset = Double(Self.window / 2) / sampleRate
            let n = Self.window
            guard samples.count > n * 2,
                  let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
            else { return }
            let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            // Up to 8 kHz: drums and attacks, without cymbal hiss swamping them.
            let bins = min(n / 2, Int(8000 / sampleRate * Double(n)))
            let zeros = [Float](repeating: 0, count: n)
            var previous = [Float](repeating: 0, count: bins)
            var magnitude = [Float](repeating: 0, count: bins)
            var flux: [Float] = []
            flux.reserveCapacity(samples.count / Self.hop)
            var start = 0
            while start + n <= samples.count {
                let frame = vDSP.multiply(samples[start..<(start + n)], hann)
                let (re, im) = dft.transform(real: frame, imaginary: zeros)
                var sum: Float = 0
                for k in 1..<bins {
                    // Log compression, so quiet attacks count, not only the loudest.
                    let m = log1pf(100 * (re[k] * re[k] + im[k] * im[k]).squareRoot())
                    magnitude[k] = m
                    let rise = m - previous[k]
                    if rise > 0 { sum += rise }
                }
                swap(&previous, &magnitude)
                flux.append(sum)
                start += Self.hop
            }
            // Take away the moving average (0.4 s) so only peaks above the texture remain.
            let span = max(1, Int(0.2 * fps))
            var prefix = [Float](repeating: 0, count: flux.count + 1)
            for i in 0..<flux.count { prefix[i + 1] = prefix[i] + flux[i] }
            var onset = [Float](repeating: 0, count: flux.count)
            for i in 0..<flux.count {
                let lo = max(0, i - span), hi = min(flux.count, i + span + 1)
                let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
                onset[i] = max(0, flux[i] - mean)
            }
            // A light smoothing keeps a peak from falling between two hops.
            values = onset.indices.map { i in
                let a = onset[max(0, i - 1)], b = onset[i], c = onset[min(onset.count - 1, i + 1)]
                return 0.25 * a + 0.5 * b + 0.25 * c
            }
        }

        func index(_ time: Double) -> Double { (time - offset) * fps }
        func time(_ index: Double) -> Double { index / fps + offset }

        func value(at index: Double) -> Float {
            guard index >= 0 else { return 0 }
            let i = Int(index)
            guard i + 1 < values.count else { return 0 }
            let f = Float(index - Double(i))
            return values[i] * (1 - f) + values[i + 1] * f
        }

        /// The song's beat period in seconds, by autocorrelation of the onsets between `from`
        /// and `to`, each candidate scored with its multiples and leaning towards 120 BPM the
        /// way listeners do when a tempo could be heard as half or double.
        func tempo(from: Double, to: Double) -> (period: Double?, confidence: Double) {
            let lo = max(0, Int(index(from))), hi = min(values.count, Int(index(to)))
            guard hi - lo > Int(fps * 15) else { return (nil, 0) }
            let slice = Array(values[lo..<hi])
            let maxLag = Int(fps * 60 / 60 * 4) + 2
            guard slice.count > maxLag * 2 else { return (nil, 0) }
            var acf = [Float](repeating: 0, count: maxLag + 1)
            slice.withUnsafeBufferPointer { buffer in
                for lag in 0...maxLag {
                    var dot: Float = 0
                    vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1, &dot, vDSP_Length(slice.count - lag))
                    acf[lag] = dot / Float(slice.count - lag)
                }
            }
            guard acf[0] > 0 else { return (nil, 0) }
            let normal = acf.map { $0 / acf[0] }
            func r(_ lag: Double) -> Double {
                let i = Int(lag)
                guard i + 1 < normal.count else { return 0 }
                let f = lag - Double(i)
                return Double(normal[i]) * (1 - f) + Double(normal[i + 1]) * f
            }
            var best: (score: Double, bpm: Double) = (-1, 0)
            var bpm = 60.0
            while bpm <= 200 {
                let lag = fps * 60 / bpm
                let comb = r(lag) + r(2 * lag) / 2 + r(3 * lag) / 3 + r(4 * lag) / 4
                let octaves = log2(bpm / 120)
                let prior = exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))
                let score = comb * prior
                if score > best.score { best = (score, bpm) }
                bpm += 0.05
            }
            // Confidence: how far the chosen lag stands above the typical correlation.
            let lagRange = Int(fps * 60 / 200)...Int(fps * 60 / 60)
            let typical = lagRange.map { Double(normal[$0]) }.sorted()[lagRange.count / 2]
            let confidence = max(0, r(fps * 60 / best.bpm) - typical)
            guard best.bpm > 0 else { return (nil, confidence) }
            return (60 / best.bpm, confidence)
        }

        /// The beat grid within `from`–`to`: the period within 3 % of `near` and the phase whose
        /// beats land on the strongest onsets.
        func grid(from: Double, to: Double, near period: Double, spread: Double = 0.03) -> BeatGrid? {
            let lo = index(from), hi = index(to)
            let approx = period * fps
            guard hi - lo > approx * 8 else { return nil }
            var mean: Float = 0
            let a = max(0, Int(lo)), b = min(values.count, Int(hi))
            guard b > a else { return nil }
            values.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + a, 1, &mean, vDSP_Length(b - a)) }
            guard mean > 0 else { return nil }
            var best: (score: Float, period: Double, phase: Double) = (-1, approx, 0)
            var scale = 1 - spread
            while scale <= 1 + spread {
                let p = approx * scale
                let beats = Int((hi - lo) / p)
                var phase = 0.0
                while phase < p {
                    var sum: Float = 0
                    for k in 0..<beats { sum += value(at: lo + phase + Double(k) * p) }
                    let score = sum / Float(max(1, beats))
                    if score > best.score { best = (score, p, phase) }
                    phase += 0.25
                }
                scale += 0.0005
            }
            return BeatGrid(period: best.period / fps, anchor: time(lo + best.phase), strength: Double(best.score / mean))
        }
    }
}

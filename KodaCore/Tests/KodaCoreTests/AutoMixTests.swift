import Foundation
import Testing
@testable import KodaCore

/// AutoMix's measurements and plans, on made-up songs whose answers are known.
struct AutoMixTests {
    static let rate = TrackAnalyzer.sampleRate

    /// A song: `lead` seconds of silence, then a pad with a kick and a hat on every beat at
    /// `bpm` for `length` seconds, then `fade` seconds fading out (0: a hard stop), then
    /// `trail` seconds of silence.
    static func song(bpm: Double, lead: Double = 1.5, length: Double = 60, fade: Double = 0, trail: Double = 2) -> [Float] {
        let total = Int((lead + length + fade + trail) * rate)
        var samples = [Float](repeating: 0, count: total)
        var noise = SystemRandomNumberGenerator()
        let musicFrom = Int(lead * rate), musicTo = Int((lead + length + fade) * rate)
        let period = 60 / bpm
        for i in musicFrom..<musicTo {
            let t = Double(i) / rate
            let sinceStart = t - lead
            let beatPhase = sinceStart.truncatingRemainder(dividingBy: period)
            var x = 0.08 * sin(2 * .pi * 220 * t)
            x += 0.7 * sin(2 * .pi * 60 * beatPhase) * exp(-beatPhase / 0.08)
            x += 0.25 * (Double(UInt8.random(in: 0...255, using: &noise)) / 127.5 - 1) * exp(-beatPhase / 0.02)
            if fade > 0, sinceStart > length {
                // Down 50 dB over the fade, evenly in decibels like a mixing desk.
                x *= pow(10, -50 * (sinceStart - length) / fade / 20)
            }
            samples[i] = Float(x)
        }
        return samples
    }

    @Test func findsWhereTheMusicIsAndAHardEnding() {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 120))
        #expect(abs(a.musicStart - 1.5) < 0.1, "\(a.summary)")
        #expect(abs(a.musicEnd - 61.5) < 0.25, "\(a.summary)")
        #expect(a.ending == .hard, "\(a.summary)")
        #expect(a.introLength < 1)
    }

    @Test func findsTheTempoAndBeats() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 120))
        let bpm = try #require(a.bpm, "\(a.summary)")
        #expect(abs(bpm - 120) < 1.5, "\(a.summary)")
        let intro = try #require(a.intro)
        let outro = try #require(a.outro)
        #expect(abs(intro.period - 0.5) < 0.005)
        #expect(intro.strength > TransitionPlanner.gridStrength, "\(a.summary)")
        // Beats fall at 1.5 + k/2 s; onsets are reported a few milliseconds into the attack.
        for grid in [intro, outro] {
            let offset = (grid.anchor - 1.5).truncatingRemainder(dividingBy: 0.5)
            let error = min(abs(offset), abs(0.5 - abs(offset)))
            #expect(error < 0.03, "beat grid off by \(error) s: \(a.summary)")
        }
    }

    @Test func findsAFadeOut() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 100, length: 60, fade: 10))
        #expect(a.ending == .fade, "\(a.summary)")
        let cue = try #require(a.fadeCue)
        // 8 dB of a 50 dB fade over 10 s is 1.6 s in; the one-second window, louder on its
        // early side while the level falls, and the beat inside it, put it within a second.
        #expect(cue - (1.5 + 60 + 1.6) > -0.5 && cue - (1.5 + 60 + 1.6) < 1.2, "cue \(cue): \(a.summary)")
    }

    @Test func matchesNearTemposWithABassSwap() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 120))
        let b = TrackAnalyzer.analyze(Self.song(bpm: 124, lead: 0.7))
        let plan = try #require(TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(plan.style == .beatMatch, "\(plan.summary)")
        #expect(abs(plan.rate - 120.0 / 124) < 0.01, "\(plan.summary)")
        // The next song starts at its first sound, timed so its first beat lands on an outgoing beat.
        #expect(abs(plan.inStart - 0.68) < 0.05, "\(plan.summary)")
        let firstBeat = try #require(b.intro).beat(atOrAfter: plan.inStart)
        let landing = plan.cue + (firstBeat - plan.inStart) / plan.rate
        let landingOffset = (landing - 1.5).truncatingRemainder(dividingBy: 0.5)
        #expect(min(abs(landingOffset), 0.5 - abs(landingOffset)) < 0.03, "\(plan.summary)")
        #expect(plan.cue + plan.overlap <= a.musicEnd + 0.1)
        // Bass leaves the outgoing song and arrives in the incoming one.
        #expect(plan.outgoing.highPass(at: plan.cue) <= Automation.highPassOff)
        #expect(plan.outgoing.highPass(at: plan.cue + plan.overlap) > 250)
        #expect(plan.incoming.highPass(at: plan.inStart) > 250)
        #expect(plan.incoming.highPass(at: plan.incomingTime(plan.cue + plan.overlap)) <= Automation.highPassOff)
        #expect(plan.outgoing.gain(at: plan.cue + plan.overlap) < 0.01)
        #expect(plan.incoming.gain(at: plan.inStart) < 0.01)
    }

    @Test func doesNotStretchFarApartTempos() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 120))
        let b = TrackAnalyzer.analyze(Self.song(bpm: 140))
        let plan = try #require(TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(plan.style == .quickBlend, "\(plan.summary)")
        #expect(plan.rate == 1)
        #expect(plan.overlap >= 1.5, "a blend, not a cut: \(plan.summary)")
    }

    @Test func ridesAFadeOut() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 100, fade: 10))
        let b = TrackAnalyzer.analyze(Self.song(bpm: 140, lead: 0.3))
        let plan = try #require(TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(plan.style == .fadeRide, "\(plan.summary)")
        #expect(plan.cue > 61 && plan.cue < a.musicEnd - 2, "\(plan.summary)")
        #expect(plan.overlap >= 6, "the next song comes in while the old one is still near full")
        // The old song's own fade does the work: no second fade over most of the overlap.
        #expect(plan.outgoing.gain(at: plan.cue + 0.5 * plan.overlap) == 1)
        #expect(plan.outgoing.gain(at: plan.cue + plan.overlap) < 0.01)
        // The next song starts at its first sound, not later.
        #expect(plan.inStart <= b.musicStart)
    }

    /// A song, a long silence, then a hidden track: the song ends where the silence begins.
    @Test func leavesOutAHiddenTrack() {
        var samples = Self.song(bpm: 120, length: 60, trail: 0)
        samples += [Float](repeating: 0, count: Int(30 * Self.rate))
        samples += Self.song(bpm: 90, lead: 0, length: 20, trail: 1)
        let a = TrackAnalyzer.analyze(samples)
        #expect(abs(a.musicEnd - 61.5) < 0.3, "\(a.summary)")
        #expect(a.hiddenTail > 45, "\(a.summary)")
    }

    /// A long quiet outro after the loud part: Music hands over near its start rather than
    /// playing it out.
    @Test func handsOverEarlyOverALongQuietOutro() throws {
        var samples = Self.song(bpm: 120, length: 80, trail: 0)
        let quiet = Self.song(bpm: 120, lead: 0, length: 60, trail: 2).map { $0 * 0.1 }
        samples += quiet
        let a = TrackAnalyzer.analyze(samples)
        let b = TrackAnalyzer.analyze(Self.song(bpm: 140))
        let plan = try #require(TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(plan.cue < 90, "\(plan.summary) / \(a.summary)")
        #expect(plan.cue > 80, "\(plan.summary)")
        #expect(plan.outgoing.gain(at: plan.cue + plan.overlap) < 0.01)
    }

    /// The same song on repeat one, with a short outro section: mixed early, beats locked.
    @Test func mixesASongIntoItselfAtItsOutro() throws {
        var samples = Self.song(bpm: 120, length: 80, trail: 0)
        samples += Self.song(bpm: 120, lead: 0, length: 14, trail: 2).map { $0 * 0.45 }
        let a = TrackAnalyzer.analyze(samples)
        let plan = try #require(TransitionPlanner.plan(from: a, to: a, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(plan.style == .beatMatch, "\(plan.summary) / \(a.summary)")
        #expect(plan.reason.contains("outro section"), "\(plan.summary)")
        #expect(plan.cue < a.musicEnd - 10, "\(plan.summary)")
        #expect(abs(plan.rate - 1) < 0.005)
    }

    /// A long outro only a few dB under the song is still the song: an early mix would leave
    /// most of it unheard, so the handover waits for the ending.
    @Test func playsALongAudibleOutro() throws {
        var samples = Self.song(bpm: 120, length: 80, trail: 0)
        samples += Self.song(bpm: 120, lead: 0, length: 40, trail: 2).map { $0 * 0.45 }
        let a = TrackAnalyzer.analyze(samples)
        let plan = try #require(TransitionPlanner.plan(from: a, to: a, context: .init(outgoingEnd: a.duration, albumNeighbours: false)))
        #expect(!plan.reason.contains("outro section"), "\(plan.summary)")
        #expect(a.seconds(above: a.bodyDb - 20, from: plan.cue + plan.overlap, to: a.musicEnd) <= TransitionPlanner.maxLeftOut, "\(plan.summary)")
    }

    // MARK: Real songs, as measured from their audio

    struct Measured: Decodable {
        var duration: Double
        var analysis: TrackAnalysis
    }

    static func measured() throws -> [String: Measured] {
        let url = try #require(Bundle.module.url(forResource: "automix-songs", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: Measured].self, from: Data(contentsOf: url))
    }

    /// WILDFLOWER's quiet last section and Chemtrails' coda are heard out on repeat one;
    /// OMG's short outro is still mixed early.
    @Test func keepsRealSongsEndings() throws {
        let songs = try Self.measured()
        for name in ["wildflower", "chemtrails"] {
            let song = try #require(songs[name])
            let a = song.analysis
            let plan = try #require(TransitionPlanner.plan(from: a, to: a, context: .init(outgoingEnd: song.duration, albumNeighbours: false)))
            let leftOut = a.seconds(above: a.bodyDb - 20, from: plan.cue + plan.overlap, to: a.musicEnd)
            #expect(leftOut <= TransitionPlanner.maxLeftOut, "\(name): \(leftOut) s left out, \(plan.summary)")
        }
        let omg = try #require(songs["omg"])
        let plan = try #require(TransitionPlanner.plan(from: omg.analysis, to: omg.analysis, context: .init(outgoingEnd: omg.duration, albumNeighbours: false)))
        #expect(plan.reason.contains("outro section"), "\(plan.summary)")
    }

    /// Cupid (120 bpm, hard stop) into BIRDS OF A FEATHER (105 bpm): too far apart to stretch,
    /// so the next comes in on one of Cupid's beats seconds before the stop and takes the bass.
    @Test func blendsAHardStopIntoAnotherTempo() throws {
        let songs = try Self.measured()
        let cupid = try #require(songs["cupid"]), birds = try #require(songs["birds"])
        let a = cupid.analysis
        let plan = try #require(TransitionPlanner.plan(from: a, to: birds.analysis, context: .init(outgoingEnd: cupid.duration, albumNeighbours: false)))
        #expect(plan.style == .quickBlend, "\(plan.summary)")
        #expect(plan.rate == 1)
        #expect(plan.overlap >= 1.5 && plan.overlap <= 4.5, "\(plan.summary)")
        let grid = try #require(a.grid(near: plan.cue))
        let offBeat = abs(plan.cue - grid.beat(atOrBefore: plan.cue + grid.period / 2))
        #expect(offBeat < 0.01, "cue \(plan.cue) is \(offBeat) s off Cupid's beat")
        #expect(plan.outgoing.highPass(at: plan.cue + plan.overlap) > 250, "Cupid hands its bass over")
        #expect(plan.outgoing.gain(at: plan.cue + plan.overlap) < 0.01)
        #expect(plan.incoming.gain(at: plan.inStart) < 0.01)
        #expect(plan.incoming.highPass(at: plan.inStart + 1) <= Automation.highPassOff, "BIRDS comes in with its bass")
    }

    /// Espresso into itself measures 104.0 bpm out and 104.1 in: 0.9995, 4.6 ms over the blend.
    /// Stretching it for that was inaudible, and changing the rate back after silenced iOS 27.
    @Test func leavesAnInaudibleTempoDifferenceAlone() throws {
        let espresso = try #require(Self.measured()["espresso"])
        let a = espresso.analysis
        let plan = try #require(TransitionPlanner.plan(from: a, to: a, context: .init(outgoingEnd: espresso.duration, albumNeighbours: false)))
        #expect(plan.style == .beatMatch, "\(plan.summary)")
        #expect(plan.firstBeat != nil)
        #expect(plan.rate == 1, "\(plan.summary)")
    }

    /// A song a transition left stretched keeps playing that way, so the next one is matched to
    /// the tempo heard, back at its own whenever that keeps the beats together, and never
    /// stretched further than `maxStretch` from its own.
    @Test func plansFromTheRateTheOutgoingSongIsHeardAt() throws {
        let espresso = try #require(Self.measured()["espresso"])
        let a = espresso.analysis
        func plan(_ outgoingRate: Double) throws -> TransitionPlan {
            try #require(TransitionPlanner.plan(from: a, to: a, context: .init(outgoingEnd: espresso.duration, albumNeighbours: false,
                                                                                  outgoingRate: outgoingRate)))
        }
        // Heard 2 % fast: the next copy is played 2 % fast too, beats still locked.
        let fast = try plan(1.02)
        #expect(fast.firstBeat != nil, "\(fast.summary)")
        #expect(abs(fast.rate * 1.02 - 1.02) < 0.002, "player rate \(fast.rate * 1.02)")
        // Heard a hair fast, within what's audible: the next copy goes back to its own tempo.
        let hair = try plan(1.0005)
        #expect(abs(hair.rate * 1.0005 - 1) < 1e-9, "player rate \(hair.rate * 1.0005)")
        // Heard 7 % fast: matching would take it past 6 %, so no beat lock, its own tempo.
        let far = try plan(1.07)
        #expect(far.firstBeat == nil, "\(far.summary)")
        #expect(abs(far.rate * 1.07 - 1) < 1e-9, "player rate \(far.rate * 1.07)")
    }

    @Test func leavesAlbumTracksGapless() throws {
        let a = TrackAnalyzer.analyze(Self.song(bpm: 120))
        let b = TrackAnalyzer.analyze(Self.song(bpm: 120))
        let plan = try #require(TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: a.duration, albumNeighbours: true)))
        #expect(plan.style == .gapless)
        #expect(plan.overlap == 0)
        #expect(plan.outgoing.isEmpty && plan.incoming.isEmpty)
    }

    @Test func automationMovesFiltersByPitch() {
        var automation = Automation()
        automation.highPass = [.init(time: 0, value: 100), .init(time: 1, value: 400)]
        automation.gain = [.init(time: 0, value: 0), .init(time: 1, value: 1)]
        #expect(abs(automation.highPass(at: 0.5) - 200) < 1, "halfway in pitch is the geometric mean")
        #expect(abs(automation.gain(at: 0.25) - 0.25) < 0.001)
        #expect(automation.gain(at: -1) == 0)
        #expect(automation.gain(at: 5) == 1)
        #expect(Automation().gain(at: 3) == 1)
        #expect(Automation().highPass(at: 3) == Automation.highPassOff)
    }

    @Test func highPassTakesTheBassOut() {
        let sampleRate = 44_100.0
        var stages = [Biquad(), Biquad()]
        let coefficients = Biquad.Coefficients.highPass(300, sampleRate: sampleRate)
        stages[0].coefficients = coefficients
        stages[1].coefficients = coefficients
        func level(_ frequency: Double) -> Double {
            var sum = 0.0
            var filters = stages
            for i in 0..<Int(sampleRate) {
                var x = Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
                x = filters[0].run(x)
                x = filters[1].run(x)
                if i > Int(sampleRate / 2) { sum += Double(x * x) }
            }
            return 10 * log10(sum / (sampleRate / 2) * 2)
        }
        #expect(level(50) < -25, "a 50 Hz kick is gone")
        #expect(abs(level(2000)) < 0.5, "the mids are untouched")
    }
}

/// AutoMix against real songs. Run with `KODA_LIVE=1 swift test --filter LiveAutoMixTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KODA_LIVE"] == "1"))
struct LiveAutoMixTests {
    @Test func measuresARealSong() async throws {
        let music = YouTubeMusic(defaultsSuite: "koda.livetests")
        let analyzer = AutoMixAnalyzer(store: nil, directory: nil)
        for id in ["CnEqrgMlWLQ", "J7p4bzqLvCw"] {
            let stream = try await music.stream(for: id)
            let analysis = try #require(await analyzer.analysis(for: stream, title: id))
            print("LIVE \(id): \(analysis.summary)")
            #expect(analysis.musicEnd > analysis.musicStart + 30)
            #expect(abs(analysis.duration - (stream.duration ?? analysis.duration)) < 1.5)
            let plan = TransitionPlanner.plan(from: analysis, to: analysis, context: .init(outgoingEnd: stream.duration ?? analysis.duration, albumNeighbours: false))
            print("LIVE \(id) on repeat one: \(plan?.summary ?? "no plan")")
        }
    }
}

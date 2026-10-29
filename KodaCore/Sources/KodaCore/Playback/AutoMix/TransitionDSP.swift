import AudioToolbox
import AVFoundation
import MediaToolbox
import ObjectiveC
import os

/// The mixer channel each song plays through with AutoMix on: an `MTAudioProcessingTap` on
/// the item's audio that applies an `Automation` (gain, high-pass, low-pass) by the item's
/// own time, sample by sample, so fades never step and filter sweeps never zipper.
///
/// The render thread never waits: it takes the newest automation only when the lock is free
/// and otherwise keeps the one it has. Levels it measures are left for the player to read
/// the same way.
final class TransitionDSP: @unchecked Sendable {
    struct Meter: Sendable {
        /// The block's peak after processing, and the item time it was at.
        var peak: Float = 0
        var rms: Float = 0
        var time: Double = 0
        var gain: Float = 1
        var highPass: Float = Automation.highPassOff
        var lowPass: Float = 20_000
        /// Samples in the block that weren't numbers (an unstable filter), which play as silence.
        var nonFinite = 0
        /// Blocks processed so far: when this stops rising, the tap isn't being called.
        var blocks = 0
    }

    private struct Shared {
        var automation = Automation()
        var version = 0
        var meter = Meter()
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    let label: String

    // Render-thread state, touched only by the tap's callbacks.
    private var automation = Automation()
    private var version = -1
    private var sampleRate: Double = 44_100
    private var isFloat = true
    private var highPassStages: [[Biquad]] = []
    private var lowPassStage: [Biquad] = []
    private var highPassOn = false
    private var lowPassOn = false
    private var lastHighPass: Float = 0
    private var lastLowPass: Float = 0
    private var formatNoted = false
    private var blocksProcessed = 0

    init(label: String) {
        self.label = label
    }

    func set(_ automation: Automation) {
        shared.withLock {
            $0.automation = automation
            $0.version += 1
        }
    }

    /// Ease back to an open channel at full gain from wherever the moves are at `time`, over
    /// `seconds`, so stopping a transition part-way never clicks.
    func release(at time: Double, over seconds: Double = 0.3) {
        shared.withLock {
            let current = $0.automation
            guard !current.isEmpty else { return }
            var open = Automation()
            open.gain = Automation.ramp(time, time + seconds, from: current.gain(at: time), to: 1)
            open.highPass = Automation.ramp(time, time + seconds, from: current.highPass(at: time), to: Automation.highPassOff)
            open.lowPass = Automation.ramp(time, time + seconds, from: current.lowPass(at: time), to: 20_000)
            $0.automation = open
            $0.version += 1
        }
    }

    func clear() { set(Automation()) }

    var meter: Meter { shared.withLock { $0.meter } }

    // MARK: Attaching

    /// The channel of `item`, if it has one.
    static func of(_ item: AVPlayerItem) -> TransitionDSP? {
        objc_getAssociatedObject(item, &dspKey) as? TransitionDSP
    }

    /// Give `item` a channel. Needs the asset's audio track, so it waits for the asset to
    /// load that; before the item plays, so attaching never interrupts sound.
    @MainActor
    static func attach(to item: AVPlayerItem, label: String) async -> TransitionDSP? {
        if let existing = of(item) { return existing }
        let asset = item.asset
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            AutoMixLog.note("tap for \(label): no audio track")
            return nil
        }
        let dsp = TransitionDSP(label: label)
        guard let tap = makeTap(dsp) else {
            AutoMixLog.note("tap for \(label): MTAudioProcessingTapCreate failed")
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        objc_setAssociatedObject(item, &dspKey, dsp, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return dsp
    }

    private static func makeTap(_ dsp: TransitionDSP) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(dsp).toOpaque(),
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TransitionDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<TransitionDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                Unmanaged<TransitionDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(buffers, frames: Int(framesOut.pointee), range: range)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(dsp).release()
            return nil
        }
        return tap
    }

    // MARK: Rendering

    private func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        isFloat = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        let channels = Int(format.mChannelsPerFrame)
        highPassStages = (0..<channels).map { _ in [Biquad(), Biquad()] }
        lowPassStage = (0..<channels).map { _ in Biquad() }
        highPassOn = false
        lowPassOn = false
        if !formatNoted {
            formatNoted = true
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let line = "tap \(label): \(Int(sampleRate)) Hz, \(channels) ch, float \(isFloat), interleaved \(interleaved)"
            DispatchQueue.global(qos: .utility).async { AutoMixLog.note(line) }
        }
    }

    /// Coefficients and per-sample interpolation are refreshed every this many frames.
    private static let chunk = 32

    private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange) {
        if let fresh = shared.withLockIfAvailable({ $0.version == version ? nil : ($0.automation, $0.version) }), let fresh {
            automation = fresh.0
            version = fresh.1
        }
        guard isFloat, frames > 0, range.start.isValid else { return }
        // The list's buffers sit inline after its count; read them in place (the CoreAudio
        // overlay's UnsafeMutableAudioBufferListPointer isn't in every SDK this builds with).
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? MemoryLayout<UInt32>.stride * 2
        let first = UnsafeMutableRawPointer(list).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        let buffers = UnsafeMutableBufferPointer(start: first, count: Int(list.pointee.mNumberBuffers))
        let start = range.start.seconds
        // Item seconds per frame: faster than 1 / sampleRate while the song plays sped up.
        let step = range.duration.isValid && range.duration.seconds > 0 ? range.duration.seconds / Double(frames) : 1 / sampleRate
        var peak: Float = 0
        var sumSquares: Float = 0
        var nonFinite = 0
        blocksProcessed += 1
        let active = !automation.isEmpty || highPassOn || lowPassOn

        if active {
            var frame = 0
            var gainFrom = automation.gain(at: start)
            while frame < frames {
                let count = min(Self.chunk, frames - frame)
                let t = start + Double(frame) * step
                let gainTo = automation.gain(at: t + Double(count) * step)
                updateFilters(highPass: automation.highPass(at: t), lowPass: automation.lowPass(at: t))
                for (c, buffer) in buffers.enumerated() {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    // Interleaved buffers hold every channel; non-interleaved, one each.
                    let stride = Int(buffer.mNumberChannels)
                    for ch in 0..<stride {
                        let channel = buffers.count > 1 ? c : ch
                        guard channel < lowPassStage.count else { continue }
                        for i in 0..<count {
                            let index = (frame + i) * stride + ch
                            var x = data[index]
                            if highPassOn {
                                x = highPassStages[channel][0].run(x)
                                x = highPassStages[channel][1].run(x)
                            }
                            if lowPassOn { x = lowPassStage[channel].run(x) }
                            let g = gainFrom + (gainTo - gainFrom) * Float(i) / Float(count)
                            x *= g
                            data[index] = x
                            if !x.isFinite { nonFinite += 1 }
                            let m: Float = Swift.abs(x)
                            if m > peak { peak = m }
                            sumSquares += x * x
                        }
                    }
                }
                gainFrom = gainTo
                frame += count
            }
        } else {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<n {
                    let sample: Float = data[i]
                    if !sample.isFinite { nonFinite += 1 }
                    let m: Float = Swift.abs(sample)
                    if m > peak { peak = m }
                    sumSquares += sample * sample
                }
            }
        }
        var samples = 0
        for buffer in buffers { samples += Int(buffer.mDataByteSize) / MemoryLayout<Float>.size }
        samples = max(1, samples)
        let meter = Meter(peak: peak, rms: (sumSquares / Float(samples)).squareRoot(), time: start,
                          gain: automation.gain(at: start), highPass: highPassOn ? lastHighPass : Automation.highPassOff,
                          lowPass: lowPassOn ? lastLowPass : 20_000, nonFinite: nonFinite, blocks: blocksProcessed)
        _ = shared.withLockIfAvailable { $0.meter = meter }
    }

    private func updateFilters(highPass: Float, lowPass: Float) {
        let wantsHighPass = highPass > Automation.highPassOff
        if wantsHighPass, !highPassOn {
            // From a standstill; a few hertz above off this settles in well under a beat.
            for c in highPassStages.indices { highPassStages[c] = [Biquad(), Biquad()] }
        }
        highPassOn = wantsHighPass
        if wantsHighPass, highPass != lastHighPass {
            let coefficients = Biquad.Coefficients.highPass(highPass, sampleRate: sampleRate)
            for c in highPassStages.indices {
                highPassStages[c][0].coefficients = coefficients
                highPassStages[c][1].coefficients = coefficients
            }
            lastHighPass = highPass
        }
        let wantsLowPass = lowPass < Automation.lowPassOff
        if wantsLowPass, !lowPassOn {
            for c in lowPassStage.indices { lowPassStage[c] = Biquad(primed: true) }
        }
        lowPassOn = wantsLowPass
        if wantsLowPass, lowPass != lastLowPass {
            let coefficients = Biquad.Coefficients.lowPass(lowPass, sampleRate: sampleRate)
            for c in lowPassStage.indices { lowPassStage[c].coefficients = coefficients }
            lastLowPass = lowPass
        }
    }
}

nonisolated(unsafe) private var dspKey: UInt8 = 0

/// One second-order filter section (Butterworth, from the Audio EQ Cookbook), direct form I,
/// which stays quiet while its cutoff moves.
nonisolated struct Biquad {
    struct Coefficients {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

        static func highPass(_ frequency: Float, sampleRate: Double) -> Coefficients {
            let (cosw, alpha) = Self.terms(frequency, sampleRate)
            let a0 = 1 + alpha
            return Coefficients(b0: (1 + cosw) / 2 / a0, b1: -(1 + cosw) / a0, b2: (1 + cosw) / 2 / a0,
                                a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
        }

        static func lowPass(_ frequency: Float, sampleRate: Double) -> Coefficients {
            let (cosw, alpha) = Self.terms(frequency, sampleRate)
            let a0 = 1 + alpha
            return Coefficients(b0: (1 - cosw) / 2 / a0, b1: (1 - cosw) / a0, b2: (1 - cosw) / 2 / a0,
                                a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
        }

        private static func terms(_ frequency: Float, _ sampleRate: Double) -> (Float, Float) {
            let nyquist = Float(sampleRate / 2)
            let f = min(max(frequency, 5), nyquist * 0.95)
            let w = 2 * Float.pi * f / Float(sampleRate)
            return (cos(w), sin(w) / (2 * Float(0.7071)))
        }
    }

    var coefficients = Coefficients()
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    /// A low-pass switched on mid-song starts as if it had always been passing the signal,
    /// rather than ramping up from zero.
    private var primed = false

    init(primed: Bool = false) {
        self.primed = primed
    }

    mutating func run(_ x: Float) -> Float {
        if primed {
            primed = false
            x1 = x; x2 = x; y1 = x; y2 = x
        }
        let c = coefficients
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

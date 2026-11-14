import AVFoundation
import KodaCore
import Speech
import SwiftUI

/// Listens for a search, on the device where the phone can, and stops by itself
/// once the listener has finished speaking.
@MainActor
@Observable
final class VoiceSearch {
    enum Phase: Equatable {
        case starting
        case listening
        case blocked(String)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var transcript = ""
    /// How loud the microphone is, 0…1, for the listening animation.
    private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var finished = false
    private var onFinish: ((String) -> Void)?

    /// How long a pause ends the search, once something has been said.
    private static let endOfSpeech: Duration = .milliseconds(1400)

    func start(onFinish: @escaping (String) -> Void) async {
        self.onFinish = onFinish
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            phase = .blocked("Koda needs Speech Recognition to search by voice. You can allow it in Settings.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .blocked("Koda needs the microphone to search by voice. You can allow it in Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            phase = .failed("Voice search isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .search
            // Kept on the phone whenever the phone can do it.
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request) { [weak self] level in
                Task { @MainActor in self?.level = level }
            })
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, isFinal, failed in
                Task { @MainActor in self?.receive(text, isFinal: isFinal, failed: failed) }
            })
            phase = .listening
        } catch {
            phase = .failed("Koda couldn't start listening.")
            stopAudio()
        }
    }

    /// Stop listening without searching.
    func cancel() {
        finished = true
        task?.cancel()
        stopAudio()
    }

    /// Search for what has been heard so far.
    func finish() {
        guard !finished else { return }
        finished = true
        task?.finish()
        stopAudio()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) }
    }

    private func receive(_ text: String?, isFinal: Bool, failed: Bool) {
        guard !finished else { return }
        if let text, !text.isEmpty { transcript = text }
        if isFinal || (failed && !transcript.isEmpty) {
            finish()
            return
        }
        if failed {
            phase = .failed("Koda didn't catch that. Try again.")
            cancel()
            return
        }
        // Each new word restarts the wait; a pause after speaking ends the search.
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.endOfSpeech)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func stopAudio() {
        silence?.cancel()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        level = 0
        // Hand audio back to playback, as Koda had it.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // These run on audio and speech threads. Built outside the main actor, so
    // nothing in them is checked against it.

    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            // Speech sits around -40…-10 dB; map that onto 0…1.
            let db = 20 * log10(max(rms, 0.000_01))
            level(Double(min(max((db + 50) / 40, 0), 1)))
        }
    }

    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}

/// The listening sheet: what is heard so far, over a microphone that moves with the voice.
struct VoiceSearchSheet: View {
    /// Where the listener turns the microphone and speech recognition back on.
    static var privacySettings: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    let onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voice = VoiceSearch()

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                // Rings that grow with the voice.
                ForEach(0..<2) { ring in
                    Circle()
                        .fill(Color.accentColor.opacity(0.18 - Double(ring) * 0.07))
                        .frame(width: 92, height: 92)
                        .scaleEffect(reduceMotion ? 1 : 1 + voice.level * (0.45 + Double(ring) * 0.35))
                        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: voice.level)
                }
                Image(systemName: isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.scaledSystem(size: 34, weight: .semibold))
                    .foregroundStyle(isListening ? Color.accentColor : .secondary)
                    .frame(width: 92, height: 92)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                    .onTapGesture { if isListening { voice.finish() } }
                    .accessibilityLabel(isListening ? "Finish speaking" : "Microphone")
            }
            .frame(height: 170)

            Group {
                switch voice.phase {
                case .starting:
                    Text("Starting…").foregroundStyle(.secondary)
                case .listening:
                    Text(voice.transcript.isEmpty ? "Say a song, artist or album" : voice.transcript)
                        .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                        .contentTransition(.interpolate)
                        .animation(.smooth(duration: 0.2), value: voice.transcript)
                case .blocked(let message), .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .font(.scaled(.title3).weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .frame(minHeight: 60)

            if case .blocked = voice.phase {
                Button("Open Settings") {
                    if let url = VoiceSearchSheet.privacySettings { openURL(url) }
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Cancel", systemImage: "xmark") {
                voice.cancel()
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(16)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.start, trigger: isListening)
        .task {
            await voice.start { text in
                onSearch(text)
                dismiss()
            }
        }
        .onDisappear { voice.cancel() }
    }

    private var isListening: Bool { voice.phase == .listening }
}

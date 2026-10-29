import AVFoundation
import Foundation

/// Measures songs for AutoMix, once each: results are kept in memory and on disk by video id.
///
/// The audio comes from the song's file in `AudioStore`. A song playing or waiting on the
/// standby player is being saved whole by `CachingLoader` anyway, so the analyzer waits a
/// little for it to finish; when it doesn't (caching off, a slow connection), it fetches the
/// file once itself into a temporary file.
actor AutoMixAnalyzer {
    private let store: AudioStore?
    private let directory: URL?
    private var memory: [String: TrackAnalysis] = [:]
    private var running: [String: Task<TrackAnalysis?, Never>] = [:]

    /// How long to wait for the caching loader to finish a song before fetching it here.
    static let cacheWait: Duration = .seconds(20)

    init(store: AudioStore?, directory: URL?) {
        self.store = store
        self.directory = directory?.appending(path: "AutoMix")
        if let folder = self.directory { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    /// The song's measurements, or nil when its audio can't be had.
    func analysis(for stream: ResolvedStream, title: String) async -> TrackAnalysis? {
        let id = stream.videoId
        if let known = memory[id] { return known }
        if let saved = load(id) {
            memory[id] = saved
            AutoMixLog.note("analysis \(title) [\(id)] from disk: \(saved.summary)")
            return saved
        }
        if let task = running[id] { return await task.value }
        let store = store
        let task = Task.detached(priority: .utility) { () -> TrackAnalysis? in
            await Self.measure(stream, title: title, store: store)
        }
        running[id] = task
        let result = await task.value
        running[id] = nil
        if let result {
            memory[id] = result
            save(result, id: id)
        }
        return result
    }

    private static func measure(_ stream: ResolvedStream, title: String, store: AudioStore?) async -> TrackAnalysis? {
        let id = stream.videoId
        let began = Date()
        var source = "file"
        var temporary: URL?
        var url: URL?
        if stream.url.isFileURL {
            url = stream.url
        } else if let store {
            store.beginUse(id)
            defer { store.endUse(id) }
            let deadline = ContinuousClock.now + cacheWait
            while ContinuousClock.now < deadline {
                if store.entry(id)?.isComplete == true { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if store.entry(id)?.isComplete == true {
                url = store.fileURL(id)
                source = "cache (waited \(Date().timeIntervalSince(began).s1) s)"
            }
        }
        if url == nil {
            do {
                temporary = try await download(stream)
                url = temporary
                source = "download"
            } catch {
                AutoMixLog.note("analysis \(title) [\(id)] FAILED to fetch audio: \(error.localizedDescription)")
                return nil
            }
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        guard let url else { return nil }
        let decodeStart = Date()
        let samples: [Float]
        do {
            samples = try await decode(url, limit: stream.duration)
        } catch {
            AutoMixLog.note("analysis \(title) [\(id)] FAILED to decode: \(error.localizedDescription)")
            return nil
        }
        let decoded = Date().timeIntervalSince(decodeStart)
        guard samples.count > Int(TrackAnalyzer.sampleRate * 5) else {
            AutoMixLog.note("analysis \(title) [\(id)] FAILED: only \(samples.count) samples")
            return nil
        }
        let measureStart = Date()
        let result = TrackAnalyzer.analyze(samples)
        AutoMixLog.note("analysis \(title) [\(id)] via \(source), decode \(decoded.s2) s, measure \(Date().timeIntervalSince(measureStart).s2) s: \(result.summary)")
        return result
    }

    /// The song's audio as mono floats at the analysis rate. `limit` stops at YouTube's length,
    /// since AVFoundation reads its fragmented M4A as longer than it is.
    static func decode(_ url: URL, limit: TimeInterval?) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        if let limit, limit > 0 {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 1000))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: TrackAnalyzer.sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var mono: [Float] = []
        if let limit { mono.reserveCapacity(Int(limit * TrackAnalyzer.sampleRate) + 1024) }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer),
                  let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = max(1, Int(description.mChannelsPerFrame))
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if channels == 1 {
                mono.append(contentsOf: interleaved)
            } else {
                let frames = interleaved.count / channels
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += interleaved[f * channels + c] }
                    mono.append(sum / Float(channels))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return mono
    }

    /// The whole file into a temporary file, the way `CachingLoader` asks for it.
    private static func download(_ stream: ResolvedStream) async throws -> URL {
        var request = URLRequest(url: stream.url)
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        if let length = stream.contentLength, length > 0 {
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        }
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 else {
            throw URLError(.badServerResponse)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "automix-\(stream.videoId)-\(UUID().uuidString).m4a")
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    // MARK: Disk

    private func file(_ id: String) -> URL? { directory?.appending(path: "\(id).json") }

    private func load(_ id: String) -> TrackAnalysis? {
        guard let url = file(id), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              saved.version == TrackAnalysis.currentVersion else { return nil }
        return saved
    }

    private func save(_ analysis: TrackAnalysis, id: String) {
        guard let url = file(id), let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

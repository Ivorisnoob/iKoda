import Foundation

public struct ResolvedStream: Sendable, Equatable {
    public var videoId: String
    public var url: URL
    /// The User-Agent of the client that resolved the URL; googlevideo binds a URL to its client.
    public var userAgent: String
    public var itag: Int
    public var contentLength: Int64?
    public var duration: TimeInterval?
    /// How far the track sits above YouTube's -14 LUFS target, when the format says.
    public var loudnessDb: Double?
    /// When googlevideo stops honouring the URL (its `expire` parameter).
    public var expiresAt: Date?

    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 10 * 60
    }
}

/// Turns a video id into a playable AAC URL.
///
/// One visionOS `/player` call under Koda's visitorData. Two refusals look
/// alike from here and need the same answer, one replacement of the token:
/// `/player` saying LOGIN_REQUIRED, and googlevideo serving the opening of the
/// file then 403 past it, which a single last-byte request catches before the
/// player is handed a URL that would stall a minute in. A replacement that is
/// refused too means the verdict is on the network, so it is not repeated.
actor StreamResolver {
    private let session: URLSession
    private let identity: VisitorIdentity
    private var cache: [String: ResolvedStream] = [:]
    private var inFlight: [String: Task<ResolvedStream, Error>] = [:]
    private var videoCache: [String: VideoStream] = [:]

    init(session: URLSession, identity: VisitorIdentity) {
        self.session = session
        self.identity = identity
    }

    func resolve(_ videoId: String) async throws -> ResolvedStream {
        if let cached = cache[videoId], cached.isFresh() { return cached }
        if let running = inFlight[videoId] { return try await running.value }
        let task = Task { try await self.fetch(videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let stream = try await task.value
        cache[videoId] = stream
        if cache.count > 200 { cache = cache.filter { $0.value.isFresh() } }
        return stream
    }

    // MARK: Video

    /// A video's HLS manifest, from the same `/player` call: under the same bot check, so the same
    /// one replacement of a refused token. Cached until shortly before googlevideo stops honouring it.
    func resolveVideo(_ videoId: String) async throws -> VideoStream {
        if let cached = videoCache[videoId], cached.isFresh() { return cached }
        guard let token = await identity.current() else { throw MusicError.network }
        var stream = try await videoAttempt(videoId, token: token)
        if stream == nil {
            guard let fresh = await identity.replace(token), fresh != token else { throw MusicError.botCheck }
            stream = try await videoAttempt(videoId, token: fresh)
        }
        guard let stream else { throw MusicError.botCheck }
        videoCache[videoId] = stream
        if videoCache.count > 100 { videoCache = videoCache.filter { $0.value.isFresh() } }
        return stream
    }

    /// Nil for the bot check's two signatures: LOGIN_REQUIRED, and OK with nothing to stream.
    private func videoAttempt(_ videoId: String, token: String) async throws -> VideoStream? {
        let root = try await player(videoId, token: token)
        let status = root["playabilityStatus"]["status"].string ?? ""
        if status == "LOGIN_REQUIRED" { return nil }
        if !status.isEmpty, status != "OK" {
            throw MusicError.unplayable(root["playabilityStatus"]["reason"].nonEmpty)
        }
        guard let url = root["streamingData"]["hlsManifestUrl"].string.flatMap(URL.init(string:)) else { return nil }
        let expires = root["streamingData"]["expiresInSeconds"].double.map { Date().addingTimeInterval($0) }
        return VideoStream(videoId: videoId, url: url, isLive: root["videoDetails"]["isLive"].bool ?? false, expiresAt: expires)
    }

    func invalidate(_ videoId: String, refusedIdentity: Bool) async {
        cache[videoId] = nil
        if refusedIdentity, let token = await identity.cached {
            _ = await identity.replace(token)
        }
    }

    private func fetch(_ videoId: String) async throws -> ResolvedStream {
        guard let token = await identity.current() else { throw MusicError.network }
        switch try await attempt(videoId, token: token) {
        case .stream(let stream):
            return stream
        case .refused:
            guard let fresh = await identity.replace(token), fresh != token else { throw MusicError.botCheck }
            switch try await attempt(videoId, token: fresh) {
            case .stream(let stream): return stream
            case .refused: throw MusicError.botCheck
            }
        }
    }

    private enum Attempt {
        case stream(ResolvedStream)
        case refused
    }

    private func attempt(_ videoId: String, token: String) async throws -> Attempt {
        let root = try await player(videoId, token: token)
        let status = root["playabilityStatus"]["status"].string ?? ""
        if status == "LOGIN_REQUIRED" { return .refused }
        if !status.isEmpty, status != "OK" {
            throw MusicError.unplayable(root["playabilityStatus"]["reason"].nonEmpty)
        }
        // OK without streamingData is the bot check's other signature.
        guard root["streamingData"].exists else { return .refused }
        guard let stream = Self.pickAudio(root, videoId: videoId) else {
            throw MusicError.unplayable("No playable audio")
        }
        if await identity.isVetted(token) { return .stream(stream) }
        switch await servesLastByte(stream) {
        case .some(false): return .refused
        case .some(true): await identity.markVetted(token)
        case .none: break
        }
        return .stream(stream)
    }

    private func player(_ videoId: String, token: String) async throws -> JSON {
        var client: [String: Any] = [
            "clientName": Clients.VisionOS.name, "clientVersion": Clients.VisionOS.version,
            "hl": "en", "gl": "US", "utcOffsetMinutes": 0, "visitorData": token,
        ]
        for (k, v) in Clients.VisionOS.fields { client[k] = v }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": client],
            "contentPlaybackNonce": Self.nonce(16),
            "t": Self.nonce(12),
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?key=\(Clients.apiKey)&prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Clients.VisionOS.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(Clients.VisionOS.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Clients.VisionOS.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: "X-Goog-Visitor-Id")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MusicError.network
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try? JSON(data: data) else { throw MusicError.badResponse(code) }
        return json
    }

    /// The last byte is refused under a walled token and served under a good
    /// one. Nil when the answer would prove nothing: no length, or a clip short
    /// enough to fit inside the window googlevideo serves either way.
    private func servesLastByte(_ stream: ResolvedStream) async -> Bool? {
        guard let length = stream.contentLength, length > 0, (stream.duration ?? 0) >= 120 else { return nil }
        var request = URLRequest(url: stream.url)
        request.timeoutInterval = 6
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(length - 1)-\(length - 1)", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 206: return true
        case 403: return false
        default: return nil
        }
    }

    /// The best AAC/M4A audio-only format of the original soundtrack.
    /// AVPlayer cannot play the Opus/WebM formats, so they are never candidates.
    static func pickAudio(_ root: JSON, videoId: String) -> ResolvedStream? {
        let formats = root["streamingData"]["adaptiveFormats"].array.filter {
            let mime = $0["mimeType"].string ?? ""
            return mime.hasPrefix("audio/mp4") && $0["url"].nonEmpty != nil
        }
        // A dubbed video carries several audio tracks; keep the default one.
        let originals = formats.filter { $0["audioTrack"]["audioIsDefault"].bool == true }
        let candidates = originals.isEmpty ? formats.filter { !$0["audioTrack"].exists } : originals
        let pool = candidates.isEmpty ? formats : candidates
        guard let best = pool.max(by: { ($0["bitrate"].int ?? 0) < ($1["bitrate"].int ?? 0) }),
              let url = best["url"].string.flatMap(URL.init(string:)) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let expire = query.first { $0.name == "expire" }?.value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let durationMs = best["approxDurationMs"].double
        return ResolvedStream(
            videoId: videoId,
            url: url,
            userAgent: Clients.VisionOS.userAgent,
            itag: best["itag"].int ?? 0,
            contentLength: best["contentLength"].string.flatMap { Int64($0) },
            duration: durationMs.map { $0 / 1000 } ?? root["videoDetails"]["lengthSeconds"].double,
            loudnessDb: best["loudnessDb"].double,
            expiresAt: expire)
    }

    private static func nonce(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

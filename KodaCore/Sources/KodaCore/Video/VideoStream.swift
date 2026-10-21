import Foundation

/// Resolves a video ID into a playable HLS or progressive MP4 video stream.
///
/// Calls /player under the visionOS client with Koda's shared visitorData token.
/// Checks `streamingData.hlsManifestUrl` first: that master playlist bundles video
/// renditions (144p to 2160p) with audio and subtitles, which AVPlayer plays
/// natively. If absent, falls back to a progressive muxed MP4 from `streamingData.formats`
/// (e.g. itags 18 / 22). Caches per video ID, and drops refused tokens on failure.
actor VideoStreamResolver {
    private let session: URLSession
    private let identity: VisitorIdentity
    private var cache: [String: VideoStream] = [:]
    private var inFlight: [String: Task<VideoStream, Error>] = [:]

    init(session: URLSession, identity: VisitorIdentity) {
        self.session = session
        self.identity = identity
    }

    func resolve(_ videoId: String) async throws -> VideoStream {
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

    func invalidate(_ videoId: String, refusedIdentity: Bool) async {
        cache[videoId] = nil
        if refusedIdentity, let token = await identity.cached {
            _ = await identity.replace(token)
        }
    }

    private func fetch(_ videoId: String) async throws -> VideoStream {
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
        case stream(VideoStream)
        case refused
    }

    private func attempt(_ videoId: String, token: String) async throws -> Attempt {
        let root = try await player(videoId, token: token)
        let status = root["playabilityStatus"]["status"].string ?? ""
        if status == "LOGIN_REQUIRED" { return .refused }
        if !status.isEmpty, status != "OK" {
            throw MusicError.unplayable(root["playabilityStatus"]["reason"].nonEmpty)
        }
        guard root["streamingData"].exists else { return .refused }
        guard let stream = Self.pickStream(root, videoId: videoId) else {
            throw MusicError.unplayable("No playable video")
        }
        return .stream(stream)
    }

    private func player(_ videoId: String, token: String) async throws -> JSON {
        var client: [String: Any] = [
            "clientName": Clients.VisionOS.name,
            "clientVersion": Clients.VisionOS.version,
            "hl": "en",
            "gl": "US",
            "utcOffsetMinutes": 0,
            "visitorData": token,
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

    static func pickStream(_ root: JSON, videoId: String) -> VideoStream? {
        let streamingData = root["streamingData"]
        let duration = root["videoDetails"]["lengthSeconds"].double

        // 1. Try HLS manifest URL first
        if let hlsString = streamingData["hlsManifestUrl"].nonEmpty,
           let hlsUrl = URL(string: hlsString) {
            let expire = expireDate(from: hlsUrl)
            return VideoStream(
                videoId: videoId,
                url: hlsUrl,
                isHLS: true,
                userAgent: Clients.VisionOS.userAgent,
                duration: duration,
                expiresAt: expire
            )
        }

        // 2. Otherwise fall back to a progressive muxed MP4 from streamingData.formats
        let formats = streamingData["formats"].array.filter {
            let mime = $0["mimeType"].string ?? ""
            return mime.hasPrefix("video/mp4") && $0["url"].nonEmpty != nil
        }
        if let best = formats.max(by: { ($0["bitrate"].int ?? 0) < ($1["bitrate"].int ?? 0) }),
           let urlString = best["url"].nonEmpty,
           let url = URL(string: urlString) {
            let expire = expireDate(from: url)
            let approxMs = best["approxDurationMs"].double
            let formatDuration = approxMs.map { $0 / 1000 } ?? duration
            return VideoStream(
                videoId: videoId,
                url: url,
                isHLS: false,
                userAgent: Clients.VisionOS.userAgent,
                duration: formatDuration,
                expiresAt: expire
            )
        }

        return nil
    }

    /// When googlevideo stops honouring the URL.
    ///
    /// A media URL carries the moment in its query; an HLS manifest carries it
    /// in its path, right after `expire/`. [verified October 2026]
    private static func expireDate(from url: URL) -> Date? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "expire" })?.value,
           let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let marker = url.path.range(of: "/expire/") else { return nil }
        let digits = url.path[marker.upperBound...].prefix(while: { $0.isNumber })
        guard let seconds = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonce(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

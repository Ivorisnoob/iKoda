import Foundation

/// Request engine for www.youtube.com under the WEB client identity.
struct WebTube: Sendable {
    static let origin = "https://www.youtube.com"

    let session: URLSession
    let identity: VisitorIdentity
    let account: AccountStore?

    func request(_ endpoint: String, _ payload: [String: Any]) async throws -> JSON {
        var visitor = await identity.cached
        if visitor == nil { visitor = await identity.current() }
        var client: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": Clients.webVersion,
            "hl": "en",
            "gl": "US"
        ]
        if let visitor { client["visitorData"] = visitor }
        var body = payload
        body["context"] = ["client": client]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?key=\(Clients.apiKey)&prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Clients.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Clients.webVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let authentication = await account?.requestHeaders(for: Self.origin)
        for (field, value) in authentication ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let stamp = await account?.generation

        let recorder = CookieRecorder()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: recorder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MusicError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MusicError.badResponse(status) }
        if let account, let stamp, let http = response as? HTTPURLResponse {
            var cookies = recorder.cookies()
            for (name, value) in YouTubeCookies.setCookieValues(InnerTube.headerValues(in: http, named: "Set-Cookie"),
                                                                 for: http.url ?? URL(string: Self.origin)!) {
                cookies[name] = value
            }
            await account.note(response: http, body: data, cookies: cookies,
                               sentSession: authentication != nil, generation: stamp)
        }
        guard let json = try? JSON(data: data), !json["error"].exists else { throw MusicError.network }
        return json
    }
}

/// The YouTube video client: feeds, search, watch page, playlists, and streams.
/// One instance serves the whole app, matching YouTubeMusic's lifecycle.
public final class YouTubeVideos: Sendable {
    let api: WebTube
    let streams: VideoStreamResolver
    private let pages = PageCache()

    public init(account: AccountStore? = nil, defaultsSuite: String? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let identity = VisitorIdentity(session: session, suite: defaultsSuite)
        api = WebTube(session: session, identity: identity, account: account)
        streams = VideoStreamResolver(session: session, identity: identity)
    }

    // MARK: - Browse

    public func home() async throws -> VideoFeed {
        try await feed(browseId: "FEwhat_to_watch")
    }

    public func feed(browseId: String) async throws -> VideoFeed {
        try await pages.value("feed|\(browseId)") { [api] in
            let root = try await api.request("browse", ["browseId": browseId])
            return VideoPages.feed(root)
        }
    }

    public func feedMore(_ continuation: String) async throws -> (shelves: [VideoShelf], continuation: String?) {
        let root = try await api.request("browse", ["continuation": continuation])
        let (shelves, next) = VideoPages.feedContinuation(root)
        return (shelves, next == continuation ? nil : next)
    }

    // MARK: - Search

    public func search(_ query: String, filter: VideoSearchFilter = .all) async throws -> VideoSearchResults {
        var payload: [String: Any] = ["query": query]
        if let params = filter.params { payload["params"] = params }
        let root = try await api.request("search", payload)
        return VideoPages.search(root)
    }

    public func searchMore(_ continuation: String) async throws -> (videos: [VideoItem], channels: [VideoChannel], playlists: [VideoPlaylistSummary], continuation: String?) {
        let root = try await api.request("search", ["continuation": continuation])
        let (videos, channels, playlists, next) = VideoPages.searchContinuation(root)
        return (videos, channels, playlists, next == continuation ? nil : next)
    }

    // MARK: - Pages

    public func playlist(_ id: String) async throws -> VideoPlaylistPage {
        try await pages.value("playlist|\(id)") { [api] in
            let browseId = id.hasPrefix("VL") ? id : "VL" + id
            let root = try await api.request("browse", ["browseId": browseId])
            guard let page = VideoPages.playlist(root, id: String(id.trimmingPrefix("VL"))) else {
                throw MusicError.badResponse(200)
            }
            return page
        }
    }

    public func playlistMore(_ continuation: String) async throws -> (items: [VideoItem], continuation: String?) {
        let root = try await api.request("browse", ["continuation": continuation])
        let (items, next) = VideoPages.playlistContinuation(root)
        return (items, next == continuation ? nil : next)
    }

    public func watch(_ videoId: String) async throws -> VideoWatchPage {
        let root = try await api.request("next", ["videoId": videoId])
        guard let page = VideoPages.watch(root, videoId: videoId) else {
            throw MusicError.badResponse(200)
        }
        return page
    }

    // MARK: - Streams

    public func stream(for videoId: String) async throws -> VideoStream {
        try await streams.resolve(videoId)
    }

    public func streamFailed(_ videoId: String) async {
        await streams.invalidate(videoId, refusedIdentity: true)
    }

    public func clearPageCache() async {
        await pages.removeAll()
    }
}

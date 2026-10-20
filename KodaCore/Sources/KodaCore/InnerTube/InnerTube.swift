import Foundation

public enum MusicError: Error, Sendable, Equatable {
    /// No connection, a timeout, or a body that could not be read.
    case network
    /// YouTube answered, but not with what was asked for.
    case badResponse(Int)
    /// A verdict on the video itself: removed, private, region-blocked.
    case unplayable(String?)
    /// The bot check refused even a fresh identity; another one will not help right now.
    case botCheck
}

/// WEB_REMIX calls on music.youtube.com.
struct InnerTube: Sendable {
    /// The origin every account request signs for.
    static let origin = "https://music.youtube.com"

    let session: URLSession
    let identity: VisitorIdentity
    /// The signed-in account, or nil signed out. Held as a reference so a
    /// sign-in and a sign-out change what every future call sends without
    /// the client being rebuilt.
    let account: AccountStore?

    func music(_ endpoint: String, _ payload: [String: Any]) async throws -> JSON {
        var visitor = await identity.cached
        if visitor == nil { visitor = await identity.current() }
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": Clients.webRemixVersion, "hl": "en", "gl": "US"]
        if let visitor { client["visitorData"] = visitor }
        var body = payload
        body["context"] = ["client": client]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Clients.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Clients.webRemixVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        // Account headers ride every music call that can: signed-in reads are
        // personalised (home, the liked songs), and a public browse id answers
        // the same shape either way. Stream resolution stays anonymous on
        // purpose — the stream clients refuse the account.
        let authentication = await account?.requestHeaders(for: Self.origin)
        for (field, value) in authentication ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // The session as it stood when the request went out, so the answer can
        // be matched to it: if the account has moved to another profile since,
        // this reply is not ours to apply.
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
            // What the reply said about the session, and the cookies it
            // rotated, go back into the account — but only when the request
            // carried the session in the first place, and only if the account
            // is still the one that was asked.
            var cookies = recorder.cookies()
            for (name, value) in YouTubeCookies.setCookieValues(Self.headerValues(in: http, named: "Set-Cookie"),
                                                                 for: http.url ?? URL(string: Self.origin)!) {
                cookies[name] = value
            }
            await account.note(response: http, body: data, cookies: cookies,
                               sentSession: authentication != nil, generation: stamp)
        }
        guard let json = try? JSON(data: data), !json["error"].exists else { throw MusicError.network }
        return json
    }

    /// A response's header values by name, however the server spelled it.
    static func headerValues(in response: HTTPURLResponse, named name: String) -> [String] {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.lowercased() == name.lowercased() else { continue }
            if let value = value as? String { values.append(value) }
        }
        return values
    }
}

/// Captures the cookies a request's answer sets, including the ones set on the
/// way through a redirect chain.
///
/// Google rotates the session's `*PSIDTS` pair on the 302s inside a redirect
/// chain, and only the last hop's headers reach the caller, so the hops are
/// read as they happen. [verified on Koda for Android, August 2026]
final class CookieRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        record(response)
        completionHandler(request)
    }

    /// The cookies the chain set, by name.
    func cookies() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private func record(_ response: HTTPURLResponse) {
        let headers = InnerTube.headerValues(in: response, named: "Set-Cookie")
        guard !headers.isEmpty else { return }
        let url = response.url ?? URL(string: InnerTube.origin)!
        let found = YouTubeCookies.setCookieValues(headers, for: url)
        guard !found.isEmpty else { return }
        lock.lock()
        values.merge(found) { _, new in new }
        lock.unlock()
    }
}

/// YouTube Music: browse, search, pages, radio and streams, signed out or
/// signed in.
public final class YouTubeMusic: Sendable {
    let api: InnerTube
    let streams: StreamResolver
    private let pages = PageCache()

    public init(account: AccountStore? = nil, defaultsSuite: String? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        // Koda signs its own requests, cookie by cookie, so URLSession must
        // not add any of its own: an anonymous cookie would travel with a
        // signed-in request.
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let identity = VisitorIdentity(session: session, suite: defaultsSuite)
        api = InnerTube(session: session, identity: identity, account: account)
        streams = StreamResolver(session: session, identity: identity)
    }

    // MARK: Browse

    public func home(params: String? = nil) async throws -> ShelfPage {
        var payload: [String: Any] = ["browseId": "FEmusic_home"]
        if let params { payload["params"] = params }
        return Pages.shelves(try await api.music("browse", payload))
    }

    public func explore() async throws -> ShelfPage {
        try await pages.value("explore") { [api] in
            Pages.shelves(try await api.music("browse", ["browseId": "FEmusic_explore"]))
        }
    }

    /// YouTube Music's charts for a country, by its two-letter code ("ZZ" is global), or for
    /// the region YouTube places the listener in when nil.
    public func charts(country: String? = nil) async throws -> ShelfPage {
        try await pages.value("charts|\(country ?? "")") { [api] in
            var payload: [String: Any] = ["browseId": "FEmusic_charts"]
            if let country { payload["formData"] = ["selectedValues": [country]] }
            return Pages.shelves(try await api.music("browse", payload))
        }
    }

    /// One row of chart playlists, simplest first: the global charts, then the listener's
    /// region, then its genre or language charts. Artist charts are left out.
    public func chartPlaylists() async throws -> [PlaylistSummary] {
        async let global = try? charts(country: "ZZ")
        async let local = try? charts()
        let pages = [await global, await local].compactMap { $0 }
        guard !pages.isEmpty else { throw MusicError.network }
        var seen = Set<String>()
        var playlists: [PlaylistSummary] = []
        for page in pages {
            for shelf in page.shelves {
                for case .playlist(let playlist) in shelf.items where seen.insert(playlist.id).inserted {
                    playlists.append(playlist)
                }
            }
        }
        return playlists
    }

    public func mood(_ mood: Mood) async throws -> ShelfPage {
        try await pages.value("mood|\(mood.browseId)|\(mood.params ?? "")") { [api] in
            var payload: [String: Any] = ["browseId": mood.browseId]
            if let params = mood.params { payload["params"] = params }
            return Pages.shelves(try await api.music("browse", payload))
        }
    }

    /// Forget fetched pages, for a pull to refresh that should really fetch again.
    public func clearPageCache() async {
        await pages.removeAll()
    }

    // MARK: Search

    public func search(_ query: String, filter: SearchFilter = .all) async throws -> SearchResults {
        var payload: [String: Any] = ["query": query]
        if let params = filter.params { payload["params"] = params }
        return Pages.search(try await api.music("search", payload))
    }

    public func suggestions(_ query: String) async throws -> [String] {
        let root = try await api.music("music/get_search_suggestions", ["input": query])
        return root.objects("searchSuggestionRenderer").map { $0["suggestion"].text }.filter { !$0.isEmpty }
    }

    // MARK: Pages

    public func album(_ id: String) async throws -> AlbumPage {
        try await pages.value("album|\(id)") { try await self.fetchAlbum(id) }
    }

    private func fetchAlbum(_ id: String) async throws -> AlbumPage {
        let root = try await api.music("browse", ["browseId": id])
        guard var page = Pages.album(root, id: id) else { throw MusicError.badResponse(200) }
        // Signed out, tracks that have a music video are listed as the video.
        if page.songs.contains(where: \.isVideo), let audioId = page.audioPlaylistId,
           let audio = try? await playlistSongs("VL" + audioId) {
            page.songs = Pages.withSongVersions(page.songs, audio: audio)
        }
        return page
    }

    public func artist(_ id: String) async throws -> ArtistPage {
        try await pages.value("artist|\(id)") { [api] in
            let root = try await api.music("browse", ["browseId": id])
            guard let page = Pages.artist(root, id: id) else { throw MusicError.badResponse(200) }
            return page
        }
    }

    public func playlist(_ id: String) async throws -> PlaylistPage {
        try await pages.value("playlist|\(id)") { try await self.fetchPlaylist(id) }
    }

    private func fetchPlaylist(_ id: String) async throws -> PlaylistPage {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let root = try await api.music("browse", ["browseId": browseId])
        guard let page = Pages.playlist(root, id: String(id.trimmingPrefix("VL"))) else { throw MusicError.badResponse(200) }
        return page
    }

    /// The next page of a playlist's tracks.
    public func playlistMore(_ continuation: String) async throws -> (songs: [Song], continuation: String?) {
        let root = try await api.music("browse", ["continuation": continuation])
        let next = Pages.playlistContinuation(root)
        return (Pages.playlistSongs(root), next == continuation ? nil : next)
    }

    /// Every track of a playlist, following continuations.
    func playlistSongs(_ browseId: String, limit: Int = 1000) async throws -> [Song] {
        let root = try await api.music("browse", ["browseId": browseId])
        var songs = Pages.playlistSongs(root)
        var token = Pages.playlistContinuation(root)
        var seen = Set<String>()
        while let current = token, songs.count < limit, seen.insert(current).inserted {
            let page = try await playlistMore(current)
            songs += page.songs
            token = page.continuation
        }
        return songs
    }

    // MARK: Radio

    /// The radio that follows `videoId`, the seed itself first.
    public func radio(for videoId: String) async throws -> (songs: [Song], continuation: String?) {
        let root = try await api.music("next", [
            "videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ])
        return Pages.queue(root)
    }

    public func radioMore(for videoId: String, continuation: String) async throws -> (songs: [Song], continuation: String?) {
        let root = try await api.music("next", [
            "videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true, "continuation": continuation,
        ])
        return Pages.queue(root)
    }

    /// A playlist's own play queue (`RDCLAK…` mixes, artist mixes).
    public func watchPlaylist(_ playlistId: String, videoId: String? = nil, params: String? = nil) async throws -> [Song] {
        var payload: [String: Any] = ["playlistId": playlistId, "isAudioOnly": true]
        if let videoId { payload["videoId"] = videoId }
        if let params { payload["params"] = params }
        return Pages.queue(try await api.music("next", payload)).songs
    }

    // MARK: Account

    /// Who the signed-in account is. Nil signed out — the endpoint answers
    /// empty — or when the answer carries no account header. Signing in
    /// happens outside KodaCore, in the app's login sheet.
    public func accountIdentity() async throws -> YouTubeAccountIdentity? {
        let root = try await api.music("account/account_menu", [:])
        return YouTubeAccountIdentity.parse(root)
    }

    /// The account's own Home: its shelves, and the recommendations in them.
    ///
    /// A signed-in Home's first page opens with "Listen again", and Quick
    /// picks — the one shelf of song rows — is usually on the page after it,
    /// so the shelves are followed until the recommendations arrive.
    public func accountHome(maxPages: Int = 3) async throws -> AccountHome {
        var root = try await api.music("browse", ["browseId": "FEmusic_home"])
        var shelves: [Shelf] = []
        var quickPicks: [Song] = []
        var quickPicksTitle = "Quick picks"
        var token = AccountPages.sectionContinuation(root)
        var pages = 0
        while pages < maxPages {
            let page = AccountPages.home(root)
            shelves += page.shelves
            if quickPicks.isEmpty, !page.quickPicks.isEmpty {
                quickPicks = page.quickPicks
                quickPicksTitle = page.quickPicksTitle
            }
            pages += 1
            if !quickPicks.isEmpty { break }
            guard let next = token else { break }
            root = try await api.music("browse", ["continuation": next])
            token = AccountPages.sectionContinuation(root)
        }
        return AccountHome(shelves: shelves, quickPicks: quickPicks, quickPicksTitle: quickPicksTitle)
    }

    /// The songs the account liked on YouTube Music, every page of them.
    public func accountLikedSongs(maxPages: Int = 50) async throws -> [Song] {
        var root = try await api.music("browse", ["browseId": "FEmusic_liked_videos"])
        var songs = AccountPages.likedSongs(root)
        var token = AccountPages.shelfContinuation(root)
        var pages = 1
        while pages < maxPages, let next = token {
            let page = try await api.music("browse", ["continuation": next])
            let more = AccountPages.likedSongs(page)
            songs += more
            if more.isEmpty { break }
            token = AccountPages.shelfContinuation(page)
            pages += 1
        }
        return Pages.dedupe(songs)
    }

    /// The playlists in the account's library, every page of them.
    public func accountPlaylists(maxPages: Int = 20) async throws -> [PlaylistSummary] {
        var root = try await api.music("browse", ["browseId": "FEmusic_liked_playlists"])
        var playlists = AccountPages.playlists(root)
        var token = AccountPages.gridContinuation(root)
        var pages = 1
        while pages < maxPages, let next = token {
            let page = try await api.music("browse", ["continuation": next])
            let more = AccountPages.playlists(page)
            playlists += more
            if more.isEmpty { break }
            token = AccountPages.gridContinuation(page)
            pages += 1
        }
        return Pages.dedupe(playlists)
    }

    /// Everything Koda reads out of the account. A part that cannot be read
    /// comes back empty rather than spoiling the rest.
    public func accountSnapshot() async -> AccountSnapshot {
        async let liked = (try? accountLikedSongs()) ?? []
        async let playlists = (try? accountPlaylists()) ?? []
        async let identity = try? accountIdentity()
        let (songs, lists, who) = await (liked, playlists, identity)
        return AccountSnapshot(liked: songs, playlists: lists, identity: who)
    }

    // MARK: Streams

    public func stream(for videoId: String) async throws -> ResolvedStream {
        try await streams.resolve(videoId)
    }

    /// Forget a stream googlevideo refused mid-play, so the next resolve starts fresh.
    public func streamFailed(_ videoId: String) async {
        await streams.invalidate(videoId, refusedIdentity: true)
    }
}

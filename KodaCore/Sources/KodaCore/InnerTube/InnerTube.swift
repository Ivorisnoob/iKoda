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
    /// An account call with no session, or one YouTube answered as signed out.
    case signedOut
    /// HTTP 429: YouTube wants this device to slow down. Only work nobody asked for
    /// should stand down; a listener's own request still goes when they make it.
    case rateLimited
}

/// InnerTube calls: WEB_REMIX on music.youtube.com, and WEB on www.youtube.com for video.
struct InnerTube: Sendable {
    let session: URLSession
    let identity: VisitorIdentity
    let accounts: AccountSessions

    /// Whether a call carries the active account: public pages are signed when there is
    /// one (Home is then the account's), account pages and writes need one.
    enum Signing {
        case ifSignedIn, required
    }

    /// The web client a call speaks as, and the site it goes to.
    struct Site: Sendable {
        let origin: String
        let clientName: String
        let clientId: String
        let version: String

        static let music = Site(origin: SAPISIDHash.musicOrigin, clientName: "WEB_REMIX", clientId: "67", version: Clients.webRemixVersion)
        static let web = Site(origin: "https://www.youtube.com", clientName: "WEB", clientId: "1", version: Clients.webVersion)
    }

    func music(_ endpoint: String, _ payload: [String: Any], signing: Signing = .ifSignedIn) async throws -> JSON {
        try await call(.music, endpoint, payload, signing: signing)
    }

    /// A WEB call on www.youtube.com: video feeds, search, watch pages and channels. Signed in, it
    /// carries the account (and is signed for www.youtube.com), so Home is the account's own.
    func web(_ endpoint: String, _ payload: [String: Any], signing: Signing = .ifSignedIn) async throws -> JSON {
        try await call(.web, endpoint, payload, signing: signing)
    }

    private func call(_ site: Site, _ endpoint: String, _ payload: [String: Any], signing: Signing) async throws -> JSON {
        let ticket = await accounts.ticket()
        if signing == .required, ticket?.cookies.sapisid == nil { throw MusicError.signedOut }
        var visitor = await identity.cached
        if visitor == nil { visitor = await identity.current() }
        var client: [String: Any] = ["clientName": site.clientName, "clientVersion": site.version, "hl": "en", "gl": "US"]
        if let visitor { client["visitorData"] = visitor }
        var body = payload
        body["context"] = ["client": client]

        var request = URLRequest(url: URL(string: "\(site.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Clients.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(site.origin, forHTTPHeaderField: "Origin")
        request.setValue(site.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(site.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let ticket {
            for (field, value) in SAPISIDHash.headers(for: ticket.cookies, origin: site.origin) { request.setValue(value, forHTTPHeaderField: field) }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MusicError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let ticket, let setCookie = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") {
            await accounts.received(setCookie: [setCookie], for: ticket)
        }
        if status == 429 { throw MusicError.rateLimited }
        // A write under a session YouTube no longer honours answers 401 UNAUTHENTICATED.
        if status == 401, ticket != nil || signing == .required { throw MusicError.signedOut }
        guard status == 200 else { throw MusicError.badResponse(status) }
        guard let json = try? JSON(data: data), !json["error"].exists else { throw MusicError.network }
        if let ticket, let signedIn = AccountPages.signedIn(json) {
            await accounts.note(signedIn: signedIn, for: ticket)
            if !signedIn, signing == .required { throw MusicError.signedOut }
        }
        return json
    }

    /// A signed GET to one of YouTube's tracking URLs (history pings), as the active account.
    /// Only `HistoryPing.trackingURL` builds these, so the cookies go to YouTube's hosts alone.
    func ping(_ url: URL, referer: String) async throws {
        guard let ticket = await accounts.ticket(), ticket.cookies.sapisid != nil else { throw MusicError.signedOut }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Clients.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        for (field, value) in SAPISIDHash.headers(for: ticket.cookies) { request.setValue(value, forHTTPHeaderField: field) }
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MusicError.network
        }
        let http = response as? HTTPURLResponse
        if let setCookie = http?.value(forHTTPHeaderField: "Set-Cookie") {
            await accounts.received(setCookie: [setCookie], for: ticket)
        }
        let status = http?.statusCode ?? 0
        if status == 429 { throw MusicError.rateLimited }
        guard (200..<300).contains(status) else { throw MusicError.badResponse(status) }
    }
}

/// YouTube Music: browse, search, pages, radio and streams, signed in as `accounts`'
/// active profile when there is one (see Account/). Streams are always resolved anonymously.
public final class YouTubeMusic: Sendable {
    let api: InnerTube
    let streams: StreamResolver
    private let pages = PageCache()
    /// The session requests are signed with; the app activates and clears it.
    public let accounts: AccountSessions
    /// What history `/player` calls carry; see PlaybackHistory.swift.
    let signatures: PlayerSignatureTimestamp

    public init(defaultsSuite: String? = nil, accounts: AccountSessions = AccountSessions()) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        // Cookies are Koda's to send, per request and per profile. A shared jar would
        // mix one profile's cookies into another's requests and catch rotations nobody
        // credits to the right account; signed-out calls need none (nor does Android).
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        let identity = VisitorIdentity(session: session, suite: defaultsSuite)
        self.accounts = accounts
        api = InnerTube(session: session, identity: identity, accounts: accounts)
        streams = StreamResolver(session: session, identity: identity)
        signatures = PlayerSignatureTimestamp(session: session, suite: defaultsSuite)
    }

    /// A cached page, kept per profile: signed in, pages carry the account's state
    /// (saved, subscribed), so one profile's are never shown to another.
    private func page<T: Sendable>(_ key: String, load: @Sendable () async throws -> T) async throws -> T {
        let scope = await accounts.cacheScope
        return try await pages.value(scope + "|" + key, load: load)
    }

    // MARK: Browse

    public func home(params: String? = nil) async throws -> ShelfPage {
        var payload: [String: Any] = ["browseId": "FEmusic_home"]
        if let params { payload["params"] = params }
        return Pages.shelves(try await api.music("browse", payload))
    }

    public func explore() async throws -> ShelfPage {
        try await page("explore") { [api] in
            Pages.shelves(try await api.music("browse", ["browseId": "FEmusic_explore"]))
        }
    }

    /// YouTube Music's charts for a country, by its two-letter code ("ZZ" is global), or for
    /// the region YouTube places the listener in when nil.
    public func charts(country: String? = nil) async throws -> ShelfPage {
        try await page("charts|\(country ?? "")") { [api] in
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

    /// A chart's top artists (40), for taste setup's grid: the region YouTube places the listener
    /// in when `country` is nil.
    public func chartArtists(country: String? = nil) async throws -> [ArtistSummary] {
        try await charts(country: country).artists
    }

    public func mood(_ mood: Mood) async throws -> ShelfPage {
        try await page("mood|\(mood.browseId)|\(mood.params ?? "")") { [api] in
            var payload: [String: Any] = ["browseId": mood.browseId]
            if let params = mood.params { payload["params"] = params }
            return Pages.shelves(try await api.music("browse", payload))
        }
    }

    /// A new anonymous identity, for a switch to or from an account. The token is the bot
    /// check's identity; one account's carried into another's requests is how a session gets
    /// flagged `LOGIN_REQUIRED` (Koda for Android drops it on every switch for that reason).
    public func renewVisitorIdentity() async {
        _ = await api.identity.replace(api.identity.cached)
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
        try await page("album|\(id)") { try await self.fetchAlbum(id) }
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
        try await page("artist|\(id)") { [api] in
            let root = try await api.music("browse", ["browseId": id])
            guard let page = Pages.artist(root, id: id) else { throw MusicError.badResponse(200) }
            return page
        }
    }

    public func playlist(_ id: String) async throws -> PlaylistPage {
        try await page("playlist|\(id)") { try await self.fetchPlaylist(id) }
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

    // MARK: Streams

    public func stream(for videoId: String) async throws -> ResolvedStream {
        try await streams.resolve(videoId)
    }

    /// Forget a stream googlevideo refused mid-play, so the next resolve starts fresh.
    public func streamFailed(_ videoId: String) async {
        await streams.invalidate(videoId, refusedIdentity: true)
    }
}

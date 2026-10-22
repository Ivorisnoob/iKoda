import Foundation
import Testing
@testable import KodaCore

// Fixtures: `signed-out-answer` and `account-menu-signed-out` are real responses
// (October 2026) to requests signed with a session YouTube doesn't know. The
// library fixtures are RECONSTRUCTED: Koda can't sign in to capture them, so their
// containers follow the shapes Koda for Android parses in production, filled with
// real signed-out rows from the other captures (built by .scratchpad/make_fixtures.py).
// The inline account menu and add-to-playlist answers are reconstructed the same way.

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

@Suite struct CookieTests {
    @Test func headerParsesAndKeepsPaddingInValues() {
        let cookies = YouTubeCookies(header: "Cookie: SID=abc==; HSID=x; __Secure-3PAPISID=sec/ret=\n; SID=dup")
        #expect(cookies["SID"] == "abc==")
        #expect(cookies["__Secure-3PAPISID"] == "sec/ret=")
        #expect(cookies.cookies.count == 3, "a repeated name keeps its first value")
        #expect(cookies.header == "SID=abc==; HSID=x; __Secure-3PAPISID=sec/ret=")
    }

    @Test func sapisidFallsBackToThePartitionedTwin() {
        #expect(YouTubeCookies(header: "SAPISID=a; __Secure-3PAPISID=b").sapisid == "a")
        #expect(YouTubeCookies(header: "__Secure-3PAPISID=b").sapisid == "b")
        #expect(YouTubeCookies(header: "SID=1").sapisid == nil)
        #expect(YouTubeCookies(header: "SID=1; SAPISID=a").looksSignedIn)
        #expect(!YouTubeCookies(header: "SAPISID=a").looksSignedIn)
    }

    @Test func webViewCookiesKeepOnlyYouTubes() throws {
        func cookie(_ name: String, _ value: String, _ domain: String, expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
            if let expires { properties[.expires] = expires }
            return try #require(HTTPCookie(properties: properties))
        }
        let cookies = YouTubeCookies([
            try cookie("SAPISID", "google", ".google.com"),
            try cookie("PREF", "host", "music.youtube.com"),
            try cookie("SAPISID", "youtube", ".youtube.com"),
            try cookie("SID", "sid", ".youtube.com"),
            try cookie("PREF", "domain", ".youtube.com"),
            try cookie("OLD", "gone", ".youtube.com", expires: Date(timeIntervalSince1970: 1000)),
        ])
        #expect(cookies.sapisid == "youtube", "google.com's SAPISID signs in as anonymous")
        #expect(cookies["PREF"] == "domain", "the domain-wide cookie wins over a host's")
        #expect(cookies["OLD"] == nil)
        #expect(cookies.looksSignedIn)
    }

    @Test func setCookieSplitsJoinedHeadersDespiteDateCommas() {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // September 2026
        let joined = "__Secure-1PSIDTS=new1; Domain=.youtube.com; Expires=Wed, 21 Oct 2027 07:28:00 GMT; Path=/; Secure; HttpOnly, "
            + "YSC=abc; Domain=.youtube.com; Path=/, "
            + "SIDCC=gone; Expires=Mon, 01-Jan-1990 00:00:00 GMT; Domain=.youtube.com, "
            + "APISID=dead; Max-Age=0, "
            + "NID=g; Domain=.google.com"
        let parsed = SetCookie.parse([joined], now: now)
        #expect(parsed.map(\.name) == ["__Secure-1PSIDTS", "YSC", "SIDCC", "APISID"], "google.com's cookie is dropped")
        #expect(parsed[0] == SetCookie(name: "__Secure-1PSIDTS", value: "new1", isDeletion: false))
        #expect(parsed[2].isDeletion, "expired")
        #expect(parsed[3].isDeletion, "Max-Age=0")
    }

    @Test func mergeTakesRotationsButNeverDeletesOrRollsBack() {
        let sent = YouTubeCookies(header: "SID=s; __Secure-1PSIDTS=old; SIDCC=c1; HSID=h")
        // Another response already rotated SIDCC after this request went out.
        let current = YouTubeCookies(header: "SID=s; __Secure-1PSIDTS=old; SIDCC=c2; HSID=h")
        let updates = [
            SetCookie(name: "__Secure-1PSIDTS", value: "new", isDeletion: false),
            SetCookie(name: "SIDCC", value: "c1-stale-rotation", isDeletion: false),
            SetCookie(name: "HSID", value: "", isDeletion: true),
            SetCookie(name: "YSC", value: "throwaway", isDeletion: false),
            SetCookie(name: "__Secure-3PSIDTS", value: "added", isDeletion: false),
        ]
        let merged = current.merging(updates, sent: sent)
        #expect(merged["__Secure-1PSIDTS"] == "new")
        #expect(merged["SIDCC"] == "c2", "an older response must not roll back a newer rotation")
        #expect(merged["HSID"] == "h", "deletions are never applied")
        #expect(merged["YSC"] == nil, "throwaway cookies are not taken")
        #expect(merged["__Secure-3PSIDTS"] == "added", "rotating names are taken even when new")
        #expect(merged.cookies.map(\.name) == ["SID", "__Secure-1PSIDTS", "SIDCC", "HSID", "__Secure-3PSIDTS"], "order is kept")
    }

    @Test func descriptionNeverShowsValues() {
        #expect(!String(describing: YouTubeCookies(header: "SID=secret")).contains("secret"))
    }

    @Test func codableRoundTrip() throws {
        let cookies = YouTubeCookies(header: "SID=a; SAPISID=b")
        let decoded = try JSONDecoder().decode(YouTubeCookies.self, from: JSONEncoder().encode(cookies))
        #expect(decoded == cookies)
    }
}

@Suite struct SAPISIDHashTests {
    @Test func sha1KnownVectors() {
        #expect(SHA1.hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        // The portable fallback (Linux) agrees with CryptoKit across block boundaries.
        for length in [0, 3, 55, 56, 63, 64, 65, 1000] {
            let message = Array(repeating: UInt8(ascii: "a"), count: length)
            #expect(SHA1.portableDigest(message) == SHA1.digest(message), "length \(length)")
        }
        #expect(SHA1.portableDigest(Array(repeating: UInt8(ascii: "a"), count: 1000)).map { String(format: "%02x", $0) }.joined()
            == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    @Test func authorizationMatchesTheWebClients() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SAPISIDHash.authorization(sapisid: "AbCdEfGhIjKlMnOp/QrStUvWxYz012345", at: date)
            == "SAPISIDHASH 1700000000_163e661c1ad4177128b563dfbe8b0ebfd1296a14")
    }

    @Test func headersCarryTheAccount() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let headers = SAPISIDHash.headers(for: YouTubeCookies(header: "SID=s; SAPISID=AbCdEfGhIjKlMnOp/QrStUvWxYz012345"), at: date)
        #expect(headers["Cookie"] == "SID=s; SAPISID=AbCdEfGhIjKlMnOp/QrStUvWxYz012345")
        #expect(headers["Authorization"] == "SAPISIDHASH 1700000000_163e661c1ad4177128b563dfbe8b0ebfd1296a14")
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        let unsigned = SAPISIDHash.headers(for: YouTubeCookies(header: "SID=s"))
        #expect(unsigned["Authorization"] == nil, "no empty Authorization without a SAPISID")
    }
}

private final class MemoryStore: AccountCookieStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [UUID: YouTubeCookies] = [:]
    func save(_ cookies: YouTubeCookies, for profileID: UUID) { lock.withLock { saved[profileID] = cookies } }
    subscript(id: UUID) -> YouTubeCookies? { lock.withLock { saved[id] } }
}

@Suite struct AccountSessionTests {
    let a = UUID(), b = UUID()
    let rotation = ["__Secure-1PSIDTS=fresh; Domain=.youtube.com; Path=/"]

    @Test func activeSessionSignsRequests() async {
        let sessions = AccountSessions()
        #expect(await sessions.ticket() == nil)
        await sessions.activate(AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=1; SAPISID=x")))
        #expect(await sessions.ticket()?.profileID == a)
        #expect(await sessions.cacheScope != "")
        await sessions.deactivate()
        #expect(await sessions.ticket() == nil)
        #expect(await sessions.cacheScope == "")
    }

    @Test func rotationsGoToTheProfileThatAskedEvenAfterASwitch() async throws {
        let store = MemoryStore()
        let sessions = AccountSessions(store: store)
        await sessions.activate(AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=a; __Secure-1PSIDTS=old")))
        let ticket = try #require(await sessions.ticket())
        await sessions.activate(AccountSession(profileID: b, cookies: YouTubeCookies(header: "SID=b; __Secure-1PSIDTS=bee")))
        await sessions.received(setCookie: rotation, for: ticket)
        #expect(await sessions.cookies(for: a)?["__Secure-1PSIDTS"] == "fresh")
        #expect(store[a]?["__Secure-1PSIDTS"] == "fresh")
        #expect(await sessions.cookies(for: b)?["__Secure-1PSIDTS"] == "bee", "never into another profile")
        #expect(store[b] == nil)
    }

    @Test func activatingAgainKeepsRotatedCookies() async throws {
        let sessions = AccountSessions()
        let original = AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=a; __Secure-1PSIDTS=old"))
        await sessions.activate(original)
        await sessions.received(setCookie: rotation, for: try #require(await sessions.ticket()))
        await sessions.deactivate()
        await sessions.activate(original) // the app's copy predates the rotation
        #expect(await sessions.active?.cookies["__Secure-1PSIDTS"] == "fresh")
    }

    @Test func anEndedSignInWritesNothing() async throws {
        let store = MemoryStore()
        let sessions = AccountSessions(store: store)
        await sessions.activate(AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=a; __Secure-1PSIDTS=old")))
        let stale = try #require(await sessions.ticket())
        await sessions.signIn(AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=new")))
        await sessions.received(setCookie: rotation, for: stale)
        await sessions.note(signedIn: false, for: stale)
        #expect(store[a] == YouTubeCookies(header: "SID=new"), "a fresh sign-in is saved; the old one's rotation isn't")
        #expect(await sessions.signedIn(a) == nil)

        let current = try #require(await sessions.ticket())
        await sessions.forget(a)
        await sessions.received(setCookie: rotation, for: current)
        #expect(store[a] == YouTubeCookies(header: "SID=new"))
        #expect(await sessions.active == nil)
    }

    @Test func verdictsAreReportedOncePerChange() async throws {
        let sessions = AccountSessions()
        await sessions.activate(AccountSession(profileID: a, cookies: YouTubeCookies(header: "SID=a")))
        let ticket = try #require(await sessions.ticket())
        await sessions.note(signedIn: true, for: ticket)
        await sessions.note(signedIn: true, for: ticket)
        await sessions.activate(AccountSession(profileID: b, cookies: YouTubeCookies(header: "SID=b")))
        await sessions.note(signedIn: false, for: ticket) // lands after the switch: still a's
        var iterator = sessions.verdicts.makeAsyncIterator()
        #expect(await iterator.next() == AccountVerdict(profileID: a, signedIn: true))
        #expect(await iterator.next() == AccountVerdict(profileID: a, signedIn: false))
        #expect(await sessions.signedIn(a) == false)
        #expect(await sessions.signedIn(b) == nil)
    }
}

@Suite struct AccountPageTests {
    @Test func verdictFromARealSignedOutAnswer() throws {
        #expect(AccountPages.signedIn(try fixture("signed-out-answer")) == false)
        #expect(AccountPages.signedIn(try fixture("library-albums")) == true)
        #expect(AccountPages.signedIn(try json(#"{"responseContext":{}}"#)) == nil, "no verdict proves nothing")
    }

    @Test func signedOutAccountMenuHasNoAccount() throws {
        #expect(AccountPages.accountInfo(try fixture("account-menu-signed-out")) == nil)
    }

    @Test func accountMenu() throws {
        // Reconstructed from the paths Android and ytmusicapi read, around the real signed-out menu.
        let root = try json(#"""
        {"responseContext":{"mainAppWebResponseContext":{"datasyncId":"112233445566778899000||","loggedOut":false}},
         "actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{
           "header":{"activeAccountHeaderRenderer":{
             "accountName":{"runs":[{"text":"Ivor"}]},
             "channelHandle":{"runs":[{"text":"@ivorisnoob"}]},
             "accountPhoto":{"thumbnails":[{"url":"https://yt3.ggpht.com/abc=s88-c-k","width":88,"height":88},
                                           {"url":"https://yt3.ggpht.com/abc=s176-c-k","width":176,"height":176}]}}},
           "sections":[{"multiPageMenuSectionRenderer":{"items":[
             {"compactLinkRenderer":{"title":{"runs":[{"text":"Get Music Premium"}]},
               "navigationEndpoint":{"browseEndpoint":{"browseId":"SPunlimited"}}}},
             {"compactLinkRenderer":{"title":{"runs":[{"text":"Your channel"}]},
               "navigationEndpoint":{"browseEndpoint":{"browseId":"UCabc123"}}}}]}}]}}}}]}
        """#)
        let info = try #require(AccountPages.accountInfo(root))
        #expect(info.name == "Ivor")
        #expect(info.handle == "@ivorisnoob")
        #expect(info.channelId == "UCabc123")
        #expect(info.photo?.width == 176)
        #expect(info.datasyncId == "112233445566778899000||", "kept verbatim")
    }

    @Test func libraryAlbumsFollowTheirGridOnly() throws {
        let root = try fixture("library-albums")
        let items = AccountPages.libraryItems(root)
        #expect(items.count == 2)
        #expect(items.allSatisfy { if case .album(let a) = $0 { return a.id.hasPrefix("MPRE") }; return false })
        #expect(AccountPages.libraryContinuation(root) == "ALBUMS-2", "not the section list's token")
        let more = try fixture("library-albums-continuation")
        #expect(AccountPages.libraryItems(more).count == 2)
        #expect(AccountPages.libraryContinuation(more) == nil)
    }

    @Test func libraryPlaylistsSkipTheNewPlaylistCard() throws {
        let items = AccountPages.libraryItems(try fixture("library-playlists"))
        let playlists = items.compactMap { if case .playlist(let p) = $0 { return p }; return nil }
        #expect(playlists.count == 4, "Liked Music and three playlists; the New playlist card is no item")
        #expect(playlists.contains { $0.id == "LM" })
        #expect(playlists.allSatisfy { !$0.id.hasPrefix("VL") })
    }

    @Test func libraryArtists() throws {
        let items = AccountPages.libraryItems(try fixture("library-artists"))
        let artists = items.compactMap { if case .artist(let a) = $0 { return a }; return nil }
        #expect(artists.count == items.count && artists.count >= 2)
        #expect(artists.allSatisfy { $0.id.hasPrefix("UC") })
        #expect(artists.first?.name == "Travis Scott")
    }

    @Test func likedSongsAcrossPages() throws {
        let first = try fixture("liked-songs")
        let songs = AccountPages.librarySongs(first)
        #expect(songs.map(\.id) == ["60ItHLz5WEA", "PT2_F-1esPk", "euCqAq6BRa4"], "the Shuffle all row is no song")
        #expect(songs.allSatisfy { !$0.title.isEmpty && !$0.artistLine.isEmpty })
        #expect(AccountPages.libraryContinuation(first) == "LIKED-2")
        let next = try fixture("liked-songs-continuation")
        #expect(AccountPages.librarySongs(next).map(\.id) == ["kOkQ4T5WO9E", "34Na4j8AVgA", "m7Bc3pLyij0"])
        #expect(AccountPages.libraryContinuation(next) == nil)
    }

    @Test func addToPlaylistOptions() throws {
        // Reduced from the shape Android's PlaylistMembershipTest captured (September 2026, www), with titles.
        let root = try json(#"""
        {"contents":[{"addToPlaylistRenderer":{"playlists":[
          {"playlistAddToOptionRenderer":{"playlistId":"WL","title":{"simpleText":"Watch later"},"containsSelectedVideos":"NONE"}},
          {"playlistAddToOptionRenderer":{"playlistId":"PLa","title":{"simpleText":"Road trip"},"containsSelectedVideos":"ALL"}},
          {"playlistAddToOptionRenderer":{"playlistId":"PLb","title":{"runs":[{"text":"Gym"}]},"containsSelectedVideos":"NONE"}},
          {"playlistAddToOptionRenderer":{"playlistId":"PLc","title":{"simpleText":"Sleep"}}}
        ]}}]}
        """#)
        #expect(AccountPages.addToPlaylistOptions(root) == [
            EditablePlaylist(id: "PLa", title: "Road trip", containsSongs: true),
            EditablePlaylist(id: "PLb", title: "Gym", containsSongs: false),
            EditablePlaylist(id: "PLc", title: "Sleep", containsSongs: nil),
        ])
    }

    @Test func writeAnswers() throws {
        #expect(AccountPages.createdPlaylistId(try json(#"{"playlistId":"PLnew"}"#)) == "PLnew")
        #expect(AccountPages.editSucceeded(try json(#"{"status":"STATUS_SUCCEEDED"}"#)))
        #expect(!AccountPages.editSucceeded(try json(#"{"status":"STATUS_FAILED"}"#)))
        #expect(!AccountPages.editSucceeded(try json("{}")), "a 200 that did nothing")
    }
}

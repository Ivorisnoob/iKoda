import Foundation
import Testing
@testable import KodaCore

/// The cookie arithmetic, the signing and the parsing of a YouTube session.
@Suite struct YouTubeSessionTests {
    @Test func mergesOnlyWhatItMay() {
        let existing = "SID=abc; SAPISID=xyz; __Secure-3PSIDTS=old; VISITOR_INFO1_LIVE=keepme"
        let merged = YouTubeCookies.merge(existing: existing, adding: [
            "__Secure-3PSIDTS": "new",
            "YSC": "throwaway",
            "SID": "rotated",
        ])
        #expect(merged.contains("__Secure-3PSIDTS=new"))
        #expect(merged.contains("SID=rotated"))
        #expect(!merged.contains("YSC"), "a cookie nothing authenticates with is not kept")
        #expect(merged.contains("VISITOR_INFO1_LIVE=keepme"), "nothing is ever taken away")
        // The order of the jar is kept.
        #expect(merged.split(separator: ";").first.map { $0.hasPrefix("SID=") } == true)
    }

    @Test func readsTheSessionSecret() {
        let header = "SID=abc; __Secure-3PAPISID=secret"
        #expect(YouTubeCookies.sapisid(in: header) == "secret")
        #expect(YouTubeCookies.missing(header).isEmpty, "the secret may come under either name")
        #expect(YouTubeCookies.missing("__Secure-3PAPISID=secret") == ["SID"])
        #expect(YouTubeCookies.missing("SAPISID=secret").contains("SID"))
    }

    @Test func readsOnlyYouTubeCookies() throws {
        let youtube = try #require(HTTPCookie(properties: [
            .domain: ".youtube.com", .path: "/", .name: "SID", .value: "abc",
        ]))
        let google = try #require(HTTPCookie(properties: [
            .domain: ".google.com", .path: "/", .name: "SAPISID", .value: "wrong",
        ]))
        let header = try #require(YouTubeSession.header(from: [youtube, google]))
        #expect(header.contains("SID=abc"))
        #expect(!header.contains("wrong"), "accounts.google.com's jar is not the session")
    }

    @Test func splitsAJoinedSetCookieHeader() {
        let joined = "SID=abc; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure, __Secure-3PSIDTS=xyz; Path=/; Secure"
        let pieces = YouTubeCookies.splitSetCookie(joined)
        #expect(pieces.count == 2, "the comma inside the date is not a separator")
        #expect(pieces[0].hasPrefix("SID=abc"))
        #expect(pieces[1].hasPrefix("__Secure-3PSIDTS=xyz"))
    }

    @Test func signsEachOriginOnItsOwn() throws {
        let jar = "SID=abc; SAPISID=secret"
        let music = try #require(SAPISIDHash.header(cookieString: jar, origin: "https://music.youtube.com", timestamp: 1_700_000_000))
        let web = try #require(SAPISIDHash.header(cookieString: jar, origin: "https://www.youtube.com", timestamp: 1_700_000_000))
        #expect(music.hasPrefix("SAPISIDHASH 1700000000_"))
        #expect(music != web, "the hash is per-origin")
        #expect(music.count == "SAPISIDHASH 1700000000_".count + 40)
        #expect(SAPISIDHash.header(cookieString: "SID=abc", origin: "https://music.youtube.com") == nil)
    }

    @Test func readsTheVerdictFromTheBody() {
        let signedIn = Data("{\"trackingParams\":{\"k\":\"logged_in\",\"value\":\"1\"}}".utf8)
        let signedOut = Data("{\"trackingParams\":{\"k\":\"logged_in\",\"value\":\"0\"}}".utf8)
        #expect(SessionVerdict(body: signedIn).isLoggedIn == true)
        #expect(SessionVerdict(body: signedOut).isLoggedIn == false)
        #expect(SessionVerdict(body: Data("{}".utf8)).isLoggedIn == nil)
    }

    @MainActor
    @Test func signsRequestsAndKeepsTheSessionFresh() throws {
        let store = try makeStore()
        let profile = UUID()
        store.activate(profileID: profile)
        #expect(store.isConnected == false)
        #expect(store.signIn(cookieHeader: "SAPISID=secret") == ["SID"], "a session without a SID is not one")

        store.signIn(cookieHeader: "SID=abc; SAPISID=secret")
        #expect(store.isConnected)
        let headers = try #require(store.requestHeaders(for: "https://music.youtube.com"))
        #expect(headers["Cookie"] == "SID=abc; SAPISID=secret")
        #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(headers["X-Goog-AuthUser"] == "0")

        // A rotation is not a new sign-in: the session stays, and the
        // generation does not move.
        let generation = store.generation
        store.note(response: HTTPURLResponse(url: URL(string: "https://music.youtube.com")!, statusCode: 200,
                                             httpVersion: nil, headerFields: nil)!,
                   body: Data("{\"trackingParams\":{\"k\":\"logged_in\",\"value\":\"1\"}}".utf8),
                   cookies: ["__Secure-3PSIDTS": "fresh"],
                   sentSession: true, generation: generation)
        #expect(store.generation == generation)
        #expect(store.isExpired == false)
        #expect(store.requestHeaders(for: "https://music.youtube.com")?["Cookie"]?.contains("__Secure-3PSIDTS=fresh") == true)
    }

    @MainActor
    @Test func expiresOnlyWhenYouTubeSaysSo() throws {
        let store = try makeStore()
        store.activate(profileID: UUID())
        store.signIn(cookieHeader: "SID=abc; SAPISID=secret")
        let response = HTTPURLResponse(url: URL(string: "https://music.youtube.com")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        store.note(response: response, body: Data("{\"trackingParams\":{\"k\":\"logged_in\",\"value\":\"0\"}}".utf8),
                   cookies: [:], sentSession: true, generation: store.generation)
        #expect(store.isExpired, "logged_in: 0 is the only verdict that matters")
        // A signed-out answer says nothing about the session.
        store.note(response: response, body: Data("{}".utf8), cookies: [:], sentSession: false,
                   generation: store.generation)
        #expect(store.isConnected, "an anonymous answer never touches the session")
    }

    @MainActor
    @Test func anAnswerForAnotherProfileIsDropped() throws {
        let store = try makeStore()
        store.activate(profileID: UUID())
        store.signIn(cookieHeader: "SID=abc; SAPISID=secret")
        let sent = store.generation
        // The listener switched profiles while the request was in the air.
        store.activate(profileID: UUID())

        store.note(response: HTTPURLResponse(url: URL(string: "https://music.youtube.com")!, statusCode: 200,
                                             httpVersion: nil, headerFields: nil)!,
                   body: Data("{\"trackingParams\":{\"k\":\"logged_in\",\"value\":\"0\"}}".utf8),
                   cookies: ["SID": "rotated"],
                   sentSession: true, generation: sent)
        #expect(store.isExpired == false, "the other profile's verdict is not ours")
        #expect(store.requestHeaders(for: "https://music.youtube.com") == nil, "and its cookies are not ours either")
    }

    @MainActor
    @Test func eachProfileKeepsItsOwnSession() throws {
        let store = try makeStore()
        let first = UUID()
        let second = UUID()
        store.activate(profileID: first)
        store.signIn(cookieHeader: "SID=abc; SAPISID=secret")
        #expect(store.requestHeaders(for: "https://music.youtube.com")?["Cookie"] == "SID=abc; SAPISID=secret")

        // Another profile: no session of its own, so nothing is sent.
        store.activate(profileID: second)
        #expect(store.isConnected == false)
        #expect(store.requestHeaders(for: "https://music.youtube.com") == nil)

        // Back to the first: its session is where it was left.
        store.activate(profileID: first)
        #expect(store.requestHeaders(for: "https://music.youtube.com")?["Cookie"] == "SID=abc; SAPISID=secret")
    }

    /// A store of its own, so the tests keep their sessions apart.
    @MainActor
    private func makeStore() throws -> AccountStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "koda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AccountStore(directory: directory, service: "ivors.Koda.tests.\(UUID().uuidString)")
    }

    @Test func readsTheAccountMenu() throws {
        let root = try JSON(data: Data(Self.menuJSON.utf8))
        let identity = try #require(YouTubeAccountIdentity.parse(root))
        #expect(identity.name == "Ivor")
        #expect(identity.datasyncId == "Cgt2b3IgMQ")
        #expect(identity.avatarURL?.absoluteString.contains("s512") == true)
        #expect(YouTubeAccountIdentity.parse(JSON(["actions": [Any]()])) == nil)
    }

    @Test func readsThePersonalizedHome() throws {
        let root = try JSON(data: Data(Self.homeJSON.utf8))
        let home = AccountPages.home(root)
        #expect(home.quickPicks.count == 2)
        #expect(home.quickPicks.first?.id == "song1")
        #expect(home.quickPicksTitle == "Quick picks")
        #expect(home.shelves.contains { $0.title == "Listen again" })
        #expect(AccountPages.sectionContinuation(root) == "TOKEN")
    }

    @Test func readsLikedSongsAndPlaylists() throws {
        let liked = try JSON(data: Data(Self.likedJSON.utf8))
        #expect(AccountPages.likedSongs(liked).map(\.id) == ["song1", "song2"])
        #expect(AccountPages.shelfContinuation(liked) == "LIKE-TOKEN")

        let playlists = try JSON(data: Data(Self.playlistsJSON.utf8))
        let lists = AccountPages.playlists(playlists)
        #expect(lists.count == 2)
        #expect(lists[0].id == "PL123")
        #expect(lists[0].title == "Road Trip")
        #expect(AccountPages.gridContinuation(playlists) == "GRID-TOKEN")
    }

    // MARK: Fixtures
    //
    // Valid JSON by construction: generated by .scratchpad/fixtures.py. The
    // closing delimiter sits at the margin, so each is the JSON exactly.

    static let homeJSON = """
{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Listen again"}]}}},"contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"After Hours"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_1"}}}}]}},{"musicShelfRenderer":{"title":{"runs":[{"text":"Quick picks"}]},"contents":[{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"First"}]}}}],"playlistItemData":{"videoId":"song1"}}},{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Second"}]}}}],"playlistItemData":{"videoId":"song2"}}}]}}],"continuations":[{"nextContinuationData":{"continuation":"TOKEN"}}]}}}}]}}}
"""

    static let likedJSON = """
{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"title":{"runs":[{"text":"Liked songs"}]},"contents":[{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"One"}]}}}],"playlistItemData":{"videoId":"song1"}}},{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Two"}]}}}],"playlistItemData":{"videoId":"song2"}}}],"continuations":[{"nextContinuationData":{"continuation":"LIKE-TOKEN"}}]}}],"continuations":[{"nextContinuationData":{"continuation":"LIKE-SECTION"}}]}}}}]}}}
"""

    static let playlistsJSON = """
{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Road Trip"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL123"}}}},{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Focus"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPL456"}}}}],"continuations":[{"nextContinuationData":{"continuation":"GRID-TOKEN"}}]}}],"continuations":[{"nextContinuationData":{"continuation":"GRID-TOKEN"}}]}}}}]}}}
"""

    static let menuJSON = """
{"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":{"activeAccountHeaderRenderer":{"accountName":{"simpleText":"Ivor"},"avatar":{"thumbnails":[{"url":"https://yt3.ggpht.com/a=s88","width":88,"height":88}]}}}}}}}],"responseContext":{"mainAppWebResponseContext":{"datasyncId":"Cgt2b3IgMQ"}}}
"""
}

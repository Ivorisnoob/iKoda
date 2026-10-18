import Foundation
import Testing
@testable import KodaCore

/// A session as the login capture would have made it: every name YouTube
/// hands out for `music.youtube.com`, with a stale `*PSIDTS` pair.
private let sampleSession = [
    "SID": "g.a000abcdefgh",
    "HSID": "AVh000abcdefgh_A",
    "SSID": "AVh000abcdefgh_B",
    "APISID": "P000abcdefgh/C",
    "SAPISID": "S000abcdefgh/D",
    "LOGIN_INFO": "AFmmF2swRAI%3D",
    "SIDCC": "SEC000abcdefgh",
    "__Secure-1PSID": "g.a000abcdefgh.Z",
    "__Secure-3PSID": "g.a000abcdefgh.Y",
    "__Secure-1PAPISID": "P000abcdefgh/E",
    "__Secure-3PAPISID": "S000abcdefgh/D",
    "__Secure-1PSIDTS": "sidts-C000-stale",
    "__Secure-3PSIDTS": "sidts-C000-stale",
].map { "\($0.key)=\($0.value)" }.joined(separator: "; ")

@Suite struct YouTubeCookiesTests {
    @Test func readsValues() {
        #expect(YouTubeCookies.value("SID", in: sampleSession) == "g.a000abcdefgh")
        // Base64-ish values carry '=' padding; only the first separator counts.
        #expect(YouTubeCookies.value("SAPISID", in: "SAPISID=abc=/0; SID=x") == "abc=/0")
        #expect(YouTubeCookies.value("SID", in: "SAPISID=abc; SID=") == nil)
        #expect(YouTubeCookies.value("SID", in: "") == nil)
    }

    @Test func readsTheSapisidUnderEitherName() {
        #expect(YouTubeCookies.sapisid(in: "a=1; SAPISID=one; SID=x") == "one")
        #expect(YouTubeCookies.sapisid(in: "a=1; __Secure-3PAPISID=two; SID=x") == "two")
        #expect(YouTubeCookies.sapisid(in: sampleSession) == "S000abcdefgh/D")
        #expect(YouTubeCookies.sapisid(in: "SID=x") == nil)
    }

    @Test func demandsWhatItCannotWorkWithout() {
        #expect(YouTubeCookies.missing(sampleSession) == [])
        #expect(YouTubeCookies.missing("SAPISID=one") == ["SID"])
        #expect(YouTubeCookies.missing("SID=x") == ["SAPISID"])
        #expect(YouTubeCookies.missing("") == ["SAPISID", "SID"])
        // The partitioned twin stands in for SAPISID.
        #expect(YouTubeCookies.missing("SID=x; __Secure-3PAPISID=two") == [])
    }

    @Test func tidiesPastedHeaders() {
        #expect(YouTubeCookies.normalize("SAPISID=abc; SID=x") == "SAPISID=abc; SID=x")
        #expect(YouTubeCookies.normalize("Cookie: SAPISID=abc; SID=x") == "SAPISID=abc; SID=x")
        #expect(YouTubeCookies.normalize("cookie:SAPISID=abc;SID=x") == "SAPISID=abc;SID=x")
        #expect(YouTubeCookies.normalize("\"SAPISID=abc; SID=x\"") == "SAPISID=abc; SID=x")
        #expect(YouTubeCookies.normalize("SAPISID=abc;\n  SID=x") == "SAPISID=abc; SID=x")
        #expect(YouTubeCookies.normalize("; SAPISID=abc; ; ") == "SAPISID=abc")
    }

    @Test func foldsOnlyRotations() {
        // A rotation refreshes what is known and what exists already — never
        // the throwaway cookies every response also sets.
        let rotated = YouTubeCookies.merge(existing: sampleSession, adding: [
            "__Secure-1PSIDTS": "sidts-C000-fresh",
            "__Secure-3PSIDTS": "sidts-C000-fresh",
            "__Secure-3PSIDCC": "SECnew",
            "YSC": "throwaway",
            "VISITOR_INFO1_LIVE": "throwaway2",
            "__Secure-1PUNKNOWN": "never-added",
        ])
        #expect(YouTubeCookies.value("__Secure-1PSIDTS", in: rotated) == "sidts-C000-fresh")
        #expect(YouTubeCookies.value("__Secure-3PSIDCC", in: rotated) == "SECnew")
        #expect(YouTubeCookies.value("YSC", in: rotated) == nil)
        #expect(YouTubeCookies.value("VISITOR_INFO1_LIVE", in: rotated) == nil)
        #expect(YouTubeCookies.value("__Secure-1PUNKNOWN", in: rotated) == nil)
        // Everything already stored survives untouched, in order.
        for name in ["SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
                     "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID"] {
            #expect(YouTubeCookies.value(name, in: rotated) == YouTubeCookies.value(name, in: sampleSession))
        }
        #expect(rotated == sampleSession.replacingOccurrences(of: "sidts-C000-stale", with: "sidts-C000-fresh"))
    }

    @Test func rotationNeverTearsDown() {
        // Updated in place, order preserved; nothing removed, ever.
        let merged = YouTubeCookies.merge(existing: "SID=x; SAPISID=one", adding: ["SID": "fresh", "SAPISID": "", "__Secure-1PSIDTS": "t"])
        #expect(merged == "SID=fresh; SAPISID=one; __Secure-1PSIDTS=t")
    }
}

@Suite struct SAPISIDHashTests {
    /// The signature computed independently of the code under test.
    @Test func signature() {
        let header = SAPISIDHash.header(cookieString: "SAPISID=abc; SID=x", origin: "https://music.youtube.com", timestamp: 1_621_347_300)
        #expect(header == "SAPISIDHASH 1621347300_5b23704699e77f96964c8f09697d9fd4d793776c")
    }

    @Test func refusesWithoutSapisid() {
        #expect(SAPISIDHash.header(cookieString: "SID=x", origin: "https://music.youtube.com", timestamp: 0) == nil)
    }
}

@Suite struct SessionVerdictTests {
    @Test func readsTheTrackingParam() {
        let body = #"{"trackingParams":["a",{"key":"logged_in","value":"1"}]}"#.data(using: .utf8)!
        #expect(SessionVerdict(from: body) == .init(isLoggedIn: true))
        let out = #"{"trackingParams":[{"key":"logged_in" ,"value" : "0"}]}"#.data(using: .utf8)!
        #expect(SessionVerdict(from: out) == .init(isLoggedIn: false))
    }

    @Test func readsTheResponseContext() {
        let body = #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.data(using: .utf8)!
        #expect(SessionVerdict(from: body) == .init(isLoggedIn: true))
    }

    @Test func unsignedResponsesSayNothing() {
        let body = #"{"responseContext":{"serviceTrackingParams":[]}}"#.data(using: .utf8)!
        #expect(SessionVerdict(from: body) == .init(isLoggedIn: nil))
        #expect(SessionVerdict(from: Data()) == .init(isLoggedIn: nil))
    }
}

@Suite struct AccountStoreTests {
    private func makeStore() -> AccountStore {
        // A unique service per store: several stores share one process, and a
        // shared Keychain entry would hand one test what another wrote.
        AccountStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "koda-tests-\(UUID().uuidString)"),
            service: "ivors.Koda.test.\(UUID().uuidString)")
    }

    @Test func startsSignedOut() {
        let store = makeStore()
        #expect(store.isLoggedIn == false)
        #expect(store.isExpired == false)
        #expect(store.requestHeaders(for: "https://music.youtube.com") == nil)
    }

    @Test func rejectsAndAcceptsAString() {
        let store = makeStore()
        #expect(store.addCookies("SID=x") == ["SAPISID"])
        #expect(store.isLoggedIn == false)
        let raw = "Cookie: " + YouTubeCookies.normalize(sampleSession)
        #expect(store.addCookies(raw) == [])
        #expect(store.isLoggedIn == true)
        let headers = store.requestHeaders(for: "https://music.youtube.com")
        #expect(headers?["Cookie"] == sampleSession)
        #expect(headers?["X-Goog-AuthUser"] == "0")
        #expect(headers?["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
    }

    @Test func aSignOutClearsEverything() {
        let store = makeStore()
        #expect(store.addCookies(sampleSession) == [])
        store.clearSession()
        #expect(store.isLoggedIn == false)
        #expect(store.requestHeaders(for: "https://music.youtube.com") == nil)
    }

    @Test func expiredIsReconnectNotSignedOut() {
        let store = makeStore()
        #expect(store.addCookies(sampleSession) == [])
        let body = #"{"trackingParams":[{"key":"logged_in","value":"0"}],"responseContext":{"mainAppWebResponseContext":{"datasyncId":"tag "}}}"#.data(using: .utf8)!
        store.note(response: HTTPURLResponse(), body: body, sentCookies: true)
        #expect(store.isExpired == true)
        #expect(store.datasyncId == "tag ")
        // The session keeps signing while expired: reconnect, not signed out.
        #expect(store.requestHeaders(for: "https://music.youtube.com")?["Cookie"] != nil)
        let fresh = #"{"trackingParams":[{"key":"logged_in","value":"1"}]}"#.data(using: .utf8)!
        store.note(response: HTTPURLResponse(), body: fresh, sentCookies: true)
        #expect(store.isExpired == false)
    }

    @Test func anonymousResponsesDoNothing() {
        let store = makeStore()
        #expect(store.addCookies(sampleSession) == [])
        let body = #"{"trackingParams":[{"key":"logged_in","value":"0"}]}"#.data(using: .utf8)!
        store.note(response: HTTPURLResponse(), body: body, sentCookies: false)
        #expect(store.isExpired == false)
    }

    @Test func anIdleVerdictAnnouncesNothing() {
        let store = makeStore()
        #expect(store.addCookies(sampleSession) == [])
        var announced = 0
        store.observeState { announced += 1 }
        for _ in 0..<3 {
            let body = #"{"trackingParams":[{"key":"logged_in","value":"1"}]}"#.data(using: .utf8)!
            store.note(response: HTTPURLResponse(), body: body, sentCookies: true)
        }
        // The same verdict, an id seen before, no rotation: nothing the UI
        // would want to redraw over.
        #expect(announced == 0)
    }

    @Test func aRotationIsNotANewLogin() {
        let store = makeStore()
        #expect(store.addCookies(sampleSession) == [])
        // One Set-Cookie header, as the response would carry it.
        let response = HTTPURLResponse(url: URL(string: "https://music.youtube.com/youtubei/v1/browse")!,
                                       statusCode: 200, httpVersion: nil,
                                       headerFields: ["Set-Cookie": "__Secure-1PSIDTS=sidts-C000-fresh; Path=/; Secure"])
        store.note(response: response!, body: #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.data(using: .utf8)!, sentCookies: true)
        let headers = store.requestHeaders(for: "https://music.youtube.com")
        #expect(YouTubeCookies.value("__Secure-1PSIDTS", in: headers?["Cookie"] ?? "") == "sidts-C000-fresh")
        // Every other name survives untouched.
        #expect(YouTubeCookies.value("SID", in: headers?["Cookie"] ?? "") == "g.a000abcdefgh")
        #expect(store.isExpired == false)
    }
}

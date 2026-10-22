import Foundation
import Testing
@testable import KodaCore

@Suite struct PlaybackHistoryTests {
    @Test func trackingURLsGoOnlyToYouTubesTrackingHosts() throws {
        let url = try #require(HistoryPing.trackingURL("https://s.youtube.com/api/stats/playback?ns=yt&docid=abc&c=OTHER", cpn: "CPN"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "c" }.map(\.value) == ["WEB_REMIX"], "replaced, not sent twice")
        #expect(items.contains(URLQueryItem(name: "cpn", value: "CPN")))
        #expect(items.contains(URLQueryItem(name: "ver", value: "2")))
        #expect(items.contains(URLQueryItem(name: "docid", value: "abc")))
        #expect(HistoryPing.trackingURL("http://s.youtube.com/api/stats/playback", cpn: "x") == nil)
        #expect(HistoryPing.trackingURL("https://evil.example/api/stats/playback", cpn: "x") == nil)
        #expect(HistoryPing.trackingURL("https://s.youtube.com.evil.example/x", cpn: "x") == nil)
    }

    @Test func aPlayNonceIsSixteenURLSafeCharacters() {
        let cpn = HistoryPing.cpn()
        #expect(cpn.count == 16)
        #expect(cpn.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func readsThePlayerIdAndItsSignatureTimestamp() {
        let iframe = #"var scriptUrl = 'https:\/\/www.youtube.com\/s\/player\/0004de42\/www-widgetapi.vflset\/www-widgetapi.js';"#
        #expect(PlayerSignatureTimestamp.playerId(inIframeAPI: iframe) == "0004de42")
        #expect(PlayerSignatureTimestamp.signatureTimestamp(inPlayer: #"a,signatureTimestamp:20725,b"#) == 20725)
        #expect(PlayerSignatureTimestamp.signatureTimestamp(inPlayer: #"sts="20731""#) == nil)
        #expect(PlayerSignatureTimestamp.signatureTimestamp(inPlayer: #"signatureTimestamp="20731""#) == 20731)
    }

    @Test func theEstimateIsTheBuildDayAFortnightBack() {
        // 1 October 2026 00:00 UTC is day 20728; a fortnight back is 20714.
        let date = Date(timeIntervalSince1970: 20_728 * 86_400)
        #expect(PlayerSignatureTimestamp.estimate(now: date) == 20_714)
    }

    @Test func aPlayCountsOnceAfterFifteenSeconds() {
        var threshold = HeardThreshold()
        let a = UUID(), b = UUID()
        let answers = [
            threshold.add(10, to: a, duration: 200),
            threshold.add(6, to: a, duration: 200),
            // Once per occurrence.
            threshold.add(30, to: a, duration: 200),
            // A new occurrence starts over.
            threshold.add(14, to: b, duration: 200),
            threshold.add(1, to: b, duration: 200),
        ]
        #expect(answers == [false, true, false, false, true])
    }

    @Test func aShortSongCountsAtHalfway() {
        var threshold = HeardThreshold()
        let a = UUID()
        let answers = [threshold.add(5, to: a, duration: 12), threshold.add(1, to: a, duration: 12)]
        #expect(answers == [false, true])
    }
}

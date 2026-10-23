import Foundation
import Testing
@testable import KodaCore

struct LastFMProtocolTests {
    /// The example from Last.fm's authentication spec, sorted and joined with the secret.
    @Test func signsSortedParametersWithTheSecret() {
        let signature = LastFMProtocol.signature(
            ["token": "yyyyyy", "method": "auth.getSession", "api_key": "xxxxxxxx", "format": "json"],
            secret: "ilovecher")
        #expect(signature == "1333ebf6f7dec747486b6ce965cca66b")
    }

    @Test func acceptsOnlyThirtyTwoHexDigitCredentials() {
        #expect(LastFMProtocol.isCredential("0123456789abcdef0123456789ABCDEF"))
        #expect(!LastFMProtocol.isCredential("0123456789abcdef"))
        #expect(!LastFMProtocol.isCredential("0123456789abcdef0123456789abcdeg"))
    }

    @Test func readsRecentTracksWhetherOneOrMany() throws {
        let one: [String: Any] = ["recenttracks": ["track": [
            "name": "Song", "artist": ["#text": "Artist"], "album": ["#text": "Album"],
            "@attr": ["nowplaying": "true"],
            "image": [["#text": "http://small"], ["#text": "https://large"]],
        ]]]
        let tracks = LastFMProtocol.recentTracks(one)
        #expect(tracks.count == 1)
        #expect(tracks[0].isNowPlaying)
        #expect(tracks[0].artwork == URL(string: "https://large"))

        let many: [String: Any] = ["recenttracks": ["track": [
            ["name": "A", "artist": ["#text": "X"], "date": ["uts": "1700000000"]],
            ["name": "B", "artist": ["#text": "Y"], "date": ["uts": "1700000100"]],
        ]]]
        let both = LastFMProtocol.recentTracks(many)
        #expect(both.map(\.title) == ["A", "B"])
        #expect(both[0].playedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!both[0].isNowPlaying)
    }

    @Test func readsTheProfile() {
        let profile = LastFMProtocol.profile(["user": [
            "name": "listener", "realname": "", "country": "None", "playcount": "12345",
            "registered": ["unixtime": "1200000000"], "subscriber": "0",
        ]])
        #expect(profile?.playCount == 12345)
        #expect(profile?.country == "")
        #expect(profile?.registered == Date(timeIntervalSince1970: 1_200_000_000))
    }

    @Test func readsTheScrobbleAcknowledgement() throws {
        let accepted: [String: Any] = ["scrobbles": ["@attr": ["accepted": 1, "ignored": 0],
                                                     "scrobble": ["ignoredMessage": ["code": "0", "#text": ""]]]]
        #expect(try LastFMProtocol.scrobbleCode(accepted) == 0)
        let ignored: [String: Any] = ["scrobbles": ["@attr": ["accepted": 0, "ignored": 1],
                                                    "scrobble": ["ignoredMessage": ["code": "1", "#text": "Artist ignored"]]]]
        #expect(try LastFMProtocol.scrobbleCode(ignored) == 1)
        #expect(throws: LastFMError.self) { try LastFMProtocol.scrobbleCode([:]) }
    }

    @Test func mapsAPIErrorsToWhatTheListenerCanDo() {
        #expect(LastFMError.fromAPI(code: 9, message: "") == .sessionRevoked)
        #expect(LastFMError.fromAPI(code: 14, message: "") == .notApprovedYet)
        #expect(LastFMError.fromAPI(code: 29, message: "").coolsDown)
        #expect(!LastFMError.notApprovedYet.coolsDown)
    }
}

struct LastFMListeningClockTests {
    let song = UUID()

    @Test func qualifiesAtHalfTheSongOrFourMinutes() {
        #expect(!LastFMListeningClock.qualifies(heard: 100, duration: 30))
        #expect(LastFMListeningClock.qualifies(heard: 100, duration: 200))
        #expect(!LastFMListeningClock.qualifies(heard: 99, duration: 200))
        #expect(LastFMListeningClock.qualifies(heard: 240, duration: 1200))
    }

    @Test func reportsAPlayOnceAndOnlyFromHeardTime() {
        var clock = LastFMListeningClock()
        clock.start(song, at: Date())
        var reported = 0
        for _ in 0..<40 where clock.add(5, to: song, duration: 180, at: Date()) { reported += 1 }
        #expect(reported == 1)
        #expect(clock.isSubmitted)
    }

    @Test func capsAGapSoSuspendedTimeIsNotCounted() {
        var clock = LastFMListeningClock()
        clock.start(song, at: Date())
        _ = clock.add(600, to: song, duration: 180, at: Date())
        #expect(clock.heard == 6)
    }

    @Test func aNewOccurrenceStartsOver() {
        var clock = LastFMListeningClock()
        clock.start(song, at: Date())
        _ = clock.add(5, to: song, duration: 180, at: Date())
        _ = clock.add(5, to: UUID(), duration: 180, at: Date())
        #expect(clock.heard == 5)
        #expect(!clock.isSubmitted)
    }

    @Test func leavesOutVideosAndPlaysWithoutAnArtist() {
        #expect(LastFM.isScrobblable(artist: "A", track: "B", isVideo: false))
        #expect(!LastFM.isScrobblable(artist: "A", track: "B", isVideo: true))
        #expect(!LastFM.isScrobblable(artist: " ", track: "B", isVideo: false))
    }
}

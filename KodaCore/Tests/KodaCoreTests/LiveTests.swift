import Foundation
import Testing
@testable import KodaCore

/// Against live YouTube; run with `KODA_LIVE=1 swift test --filter LiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KODA_LIVE"] == "1"))
struct LiveTests {
    let music = YouTubeMusic(defaultsSuite: "koda.livetests")

    /// A session YouTube doesn't know: public pages still load, the verdict comes back
    /// signed out, and account calls throw rather than return an empty library.
    @Test func deadSessionIsAnsweredAsSignedOut() async throws {
        let profile = UUID()
        let music = YouTubeMusic(defaultsSuite: "koda.livetests")
        await music.accounts.activate(AccountSession(profileID: profile, cookies: YouTubeCookies(header: "SID=made-up; SAPISID=AbCdEfGhIjKlMnOp/QrStUvWxYz012345")))
        var verdicts = music.accounts.verdicts.makeAsyncIterator()
        let home = try await music.home()
        #expect(!home.shelves.isEmpty)
        #expect(await verdicts.next() == AccountVerdict(profileID: profile, signedIn: false))
        await #expect(throws: MusicError.signedOut) { try await music.likedSongs() }
        await #expect(throws: MusicError.signedOut) { try await music.setLiked(videoId: "J7p4bzqLvCw", liked: true) }
    }

    @Test func searchAlbumRadioAndStream() async throws {
        let results = try await music.search("blinding lights", filter: .songs)
        let song = try #require(results.songs.first)
        #expect(song.id.count == 11)

        if let albumId = song.album?.id {
            let album = try await music.album(albumId)
            #expect(!album.songs.isEmpty)
        }

        let radio = try await music.radio(for: song.id)
        #expect(radio.songs.count > 10)

        let stream = try await music.stream(for: song.id)
        let length = try #require(stream.contentLength)
        var request = URLRequest(url: stream.url)
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(length - 1)-\(length - 1)", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
    }

    @Test func homeExploreAndArtist() async throws {
        let home = try await music.home()
        #expect(!home.shelves.isEmpty)
        let explore = try await music.explore()
        #expect(explore.shelves.contains { $0.title == "New albums & singles" })
        let artist = try await music.artist("UClYV6hHlupm_S_ObS1W-DYw")
        #expect(artist.artist.name == "The Weeknd")
        let suggestions = try await music.suggestions("weeknd")
        #expect(!suggestions.isEmpty)
    }
}

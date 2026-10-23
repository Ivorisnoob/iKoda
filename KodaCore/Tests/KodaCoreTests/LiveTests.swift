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

    /// The video side end to end, signed out: search, a watch page, its channel, a page more of
    /// the channel's videos, and an HLS stream that answers.
    @Test func videoSearchWatchChannelAndStream() async throws {
        let results = try await music.searchVideos("blender open movie")
        let video = try #require(results.videos.videos.first)
        #expect(video.id.count == 11)
        let page = try await music.watchPage(video.id)
        #expect(!page.video.title.isEmpty)
        #expect(!page.related.videos.isEmpty)
        let channelId = try #require(page.video.channel?.id)
        let channel = try await music.channel(channelId)
        #expect(!channel.channel.name.isEmpty)
        #expect(!channel.videos.videos.isEmpty)
        if let token = channel.videos.continuation {
            #expect(!(try await music.moreVideos(token, from: .browse)).videos.isEmpty)
        }
        if let token = page.related.continuation {
            #expect(!(try await music.moreVideos(token, from: .next)).videos.isEmpty)
        }
        let stream = try await music.videoStream(video.id)
        let (data, response) = try await URLSession.shared.data(from: stream.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("#EXT-X-STREAM-INF"))
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

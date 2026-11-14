import Foundation
import Testing
@testable import KodaCore

@Suite struct YouTubeLinkTests {
    private func link(_ string: String) -> YouTubeLink? { URL(string: string).flatMap(YouTubeLink.init) }

    @Test func songs() {
        #expect(link("https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=42") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://m.youtube.com/shorts/dQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("koda://watch?v=dQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
    }

    @Test func collections() {
        #expect(link("https://music.youtube.com/playlist?list=PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i") == .playlist(id: "PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i"))
        #expect(link("https://music.youtube.com/playlist?list=OLAK5uy_abc") == .playlist(id: "OLAK5uy_abc"))
        #expect(link("https://music.youtube.com/browse/MPREb_4pL8gzRtw1p") == .album(browseId: "MPREb_4pL8gzRtw1p"))
        #expect(link("https://music.youtube.com/channel/UCbulh9WdLtEXiooRcYK7SWw") == .artist(channelId: "UCbulh9WdLtEXiooRcYK7SWw"))
        #expect(link("koda://browse/MPREb_4pL8gzRtw1p") == .album(browseId: "MPREb_4pL8gzRtw1p"))
    }

    @Test func rejectsWhatHasNoPage() {
        #expect(link("https://music.youtube.com/watch?list=RDAMVMdQw4w9WgXcQ") == nil)
        #expect(link("https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(link("https://music.youtube.com/") == nil)
        #expect(link("https://youtu.be/short") == nil)
    }

    @Test func aLinkFromTheShareExtensionIsUnwrapped() throws {
        let shared = try #require(URL(string: "koda://open?url=https%3A%2F%2Fyoutu.be%2FdQw4w9WgXcQ%3Fsi%3Dabc"))
        let inner = YouTubeLink.unwrapped(shared)
        #expect(inner.absoluteString == "https://youtu.be/dQw4w9WgXcQ?si=abc")
        #expect(YouTubeLink(inner) == .song(videoId: "dQw4w9WgXcQ"))
        #expect(YouTubeLink.isVideoSite(inner))
        // Anything else is left as it came, and YouTube Music is not the video site.
        let own = try #require(URL(string: "koda://watch?v=dQw4w9WgXcQ"))
        #expect(YouTubeLink.unwrapped(own) == own)
        #expect(!YouTubeLink.isVideoSite(try #require(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"))))
    }

    @Test func downloadProgressCountsPartFetchedSongs() {
        let progress = Downloads.Progress(finished: 2, total: 8, fetching: [0.5, 0.25], current: "Song")
        #expect(progress.finished == 2)
        #expect(progress.total == 8)
        #expect(abs(progress.fraction - 2.75 / 8) < 0.0001)
        // A count that fell behind what is known never reads past the whole.
        let odd = Downloads.Progress(finished: 3, total: 1, fetching: [1], current: nil)
        #expect(odd.total == 4)
        #expect(odd.fraction == 1)
    }

    @Test func findsALinkInText() {
        #expect(YouTubeLink(text: "listen to this https://youtu.be/dQw4w9WgXcQ !!") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(YouTubeLink(text: "the weeknd") == nil)
    }
}

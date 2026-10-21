import Foundation
import Testing
@testable import KodaCore

@Suite struct YouTubeLinkTests {
    private func link(_ string: String) -> YouTubeLink? { URL(string: string).flatMap(YouTubeLink.init) }

    @Test func songs() {
        #expect(link("https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://music.youtube.com/shorts/dQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(link("koda://watch?v=dQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
    }

    @Test func videos() {
        #expect(link("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://youtube.com/watch?v=dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://www.youtube.com/shorts/dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://www.youtube.com/live/dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://m.youtube.com/shorts/dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://youtu.be/dQw4w9WgXcQ?t=42") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(link("https://youtu.be/dQw4w9WgXcQ") == .video(videoId: "dQw4w9WgXcQ"))
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

    @Test func findsALinkInText() {
        #expect(YouTubeLink(text: "listen to this https://youtu.be/dQw4w9WgXcQ !!") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(YouTubeLink(text: "watch https://www.youtube.com/watch?v=dQw4w9WgXcQ now") == .video(videoId: "dQw4w9WgXcQ"))
        #expect(YouTubeLink(text: "the weeknd") == nil)
    }
}
import Foundation
import Testing
@testable import KodaCore

@Suite struct VideoTests {
    @Test func feedParsing() throws {
        let root = try fixture("video-feed")
        let feed = VideoPages.feed(root)

        #expect(!feed.shelves.isEmpty)
        let firstShelf = try #require(feed.shelves.first)
        #expect(firstShelf.title == "Recommended")
        #expect(!firstShelf.items.isEmpty)

        let firstVideo = firstShelf.items[0]
        #expect(firstVideo.id == "b1oC7sLIgpI")
        #expect(firstVideo.title.contains("SwiftUI Fundamentals"))
        #expect(firstVideo.channel == "Sean Allen")
        #expect(firstVideo.channelId == "UCbTw29mcP12YlTt1EpUaVJw")
        #expect(firstVideo.duration != nil)
        #expect(firstVideo.viewCountText != nil)

        // Titled rich shelf
        let techShelf = try #require(feed.shelves.first(where: { $0.title == "Trending Tech" }))
        #expect(!techShelf.items.isEmpty)

        // Continuation token
        #expect(feed.continuation == "FEED_CONTINUATION_TOKEN_12345")
    }

    @Test func feedEmpty() {
        let feed = VideoPages.feed(JSON([:]))
        #expect(feed.shelves.isEmpty)
        #expect(feed.continuation == nil)
    }

    @Test func searchParsing() throws {
        let root = try fixture("video-search")
        let results = VideoPages.search(root)

        #expect(!results.videos.isEmpty)
        #expect(!results.channels.isEmpty)
        #expect(!results.playlists.isEmpty)

        // videoRenderer
        let video = try #require(results.videos.first(where: { $0.id == "b1oC7sLIgpI" }))
        #expect(video.title.contains("SwiftUI Fundamentals"))
        #expect(video.channel == "Sean Allen")
        #expect(video.channelId == "UCbTw29mcP12YlTt1EpUaVJw")

        // channelRenderer
        let channel = try #require(results.channels.first(where: { $0.id == "UCmJi5RdDLgzvkl3Ly0DRMlQ" }))
        #expect(channel.name == "Paul Hudson")
        #expect(channel.subscriberText != nil)
        #expect(channel.avatar != nil)

        // lockupViewModel as course/playlist
        let playlist = try #require(results.playlists.first(where: { $0.id == "PLwvDm4VfkdphqETTBf-DdjCoAvhai1QpO" }))
        #expect(playlist.title.contains("SwiftUI Bootcamp"))
        #expect(playlist.channel == "Swiftful Thinking")

        // Continuation token
        #expect(results.continuation != nil)
        #expect(results.continuation?.contains("CONTINUATION_REQUEST_TYPE_SEARCH") == false)
    }

    @Test func searchEmpty() {
        let results = VideoPages.search(JSON([:]))
        #expect(results.isEmpty)
        #expect(results.continuation == nil)
    }

    @Test func watchPageParsing() throws {
        let root = try fixture("video-watch")
        let page = try #require(VideoPages.watch(root, videoId: "dQw4w9WgXcQ"))

        // Video info
        #expect(page.video.id == "dQw4w9WgXcQ")
        #expect(page.video.title.contains("Never Gonna Give You Up"))
        #expect(page.viewCountText?.contains("1,828,891,032") == true)
        #expect(page.publishedText == "Oct 24, 2009")

        // Channel info
        #expect(page.channel.name == "Rick Astley")
        #expect(page.channel.id == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(page.channel.subscriberText?.contains("4.55M") == true)
        #expect(page.channel.avatar != nil)

        // Description
        #expect(page.description?.contains("official video") == true)

        // Up next videos (from lockupViewModel)
        #expect(!page.upNext.isEmpty)
        let firstUpNext = try #require(page.upNext.first)
        #expect(firstUpNext.id == "eNvUS-6PTbs")
        #expect(!firstUpNext.title.isEmpty)

        // Continuation token for upNext
        #expect(page.continuation != nil)
    }

    @Test func watchEmpty() {
        let page = VideoPages.watch(JSON([:]), videoId: "test1234567")
        #expect(page == nil)
    }

    @Test func playlistPageParsing() throws {
        let root = try fixture("video-playlist")
        let page = try #require(VideoPages.playlist(root, id: "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"))

        // Playlist summary
        #expect(page.playlist.id == "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
        #expect(page.playlist.title == "Select Lectures")
        #expect(page.playlist.itemCount != nil)
        #expect(page.playlist.thumbnail != nil)

        // Videos in playlist
        #expect(!page.items.isEmpty)
        #expect(page.items.contains { $0.id == "0VH1Lim8gL8" })
        #expect(page.items.contains { $0.id == "b1oC7sLIgpI" })

        // Continuation
        #expect(page.continuation != nil)
    }

    @Test func playlistEmpty() {
        let page = VideoPages.playlist(JSON([:]), id: "empty")
        #expect(page != nil)
        #expect(page?.items.isEmpty == true)
    }

    @Test func videoRendererBadgesAndShorts() throws {
        let liveJSON = JSON([
            "videoId": "live1234567",
            "title": ["simpleText": "Live Stream Video"],
            "ownerText": ["runs": [["text": "Live Channel"]]],
            "badges": [["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_LIVE_NOW", "label": "LIVE"]]],
        ])
        let liveVideo = try #require(VideoRows.video(from: liveJSON))
        #expect(liveVideo.isLive == true)
        #expect(liveVideo.isShort == false)

        let shortJSON = JSON([
            "videoId": "short123456",
            "title": ["simpleText": "Quick Short"],
            "ownerText": ["runs": [["text": "Creator"]]],
            "lengthText": ["simpleText": "0:45"],
        ])
        let shortVideo = try #require(VideoRows.video(from: shortJSON))
        #expect(shortVideo.isShort == true)
        #expect(shortVideo.duration == 45)
    }

    @Test func streamSelectionHLSAndMP4() {
        // HLS preferred
        let hlsJSON = JSON([
            "videoDetails": ["lengthSeconds": "180"],
            "streamingData": [
                "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1729000000/test.m3u8",
                "formats": [
                    ["itag": 18, "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "bitrate": 500000, "url": "https://googlevideo.com/videoplayback?expire=1729000000"]
                ]
            ]
        ])
        let hlsStream = VideoStreamResolver.pickStream(hlsJSON, videoId: "hlsVid12345")
        #expect(hlsStream != nil)
        #expect(hlsStream?.isHLS == true)
        #expect(hlsStream?.url.absoluteString.contains("hls_variant") == true)
        #expect(hlsStream?.duration == 180)
        #expect(hlsStream?.expiresAt != nil)

        // MP4 fallback when no HLS
        let mp4JSON = JSON([
            "videoDetails": ["lengthSeconds": "240"],
            "streamingData": [
                "formats": [
                    ["itag": 18, "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "bitrate": 500000, "url": "https://googlevideo.com/videoplayback?expire=1729000000"]
                ]
            ]
        ])
        let mp4Stream = VideoStreamResolver.pickStream(mp4JSON, videoId: "mp4Vid12345")
        #expect(mp4Stream != nil)
        #expect(mp4Stream?.isHLS == false)
        #expect(mp4Stream?.duration == 240)

        // Neither returns nil
        let noneJSON = JSON(["streamingData": [:]])
        #expect(VideoStreamResolver.pickStream(noneJSON, videoId: "none") == nil)
    }

    @Test func videoQualityLadder() {
        #expect(VideoQuality.automatic.peakBitRate == 0.0)
        #expect(VideoQuality.automatic.maxHeight == 0)

        #expect(VideoQuality.p360.maxHeight == 360)
        #expect(VideoQuality.p720.maxHeight == 720)
        #expect(VideoQuality.p1080.maxHeight == 1080)

        #expect(VideoQuality.p360.peakBitRate < VideoQuality.p720.peakBitRate)
        #expect(VideoQuality.p720.peakBitRate < VideoQuality.p1080.peakBitRate)
    }

    @Test func searchFilterParams() {
        #expect(VideoSearchFilter.all.params == nil)
        #expect(VideoSearchFilter.videos.params == "EgIQAQ%3D%3D")
        #expect(VideoSearchFilter.channels.params == "EgIQAg%3D%3D")
        #expect(VideoSearchFilter.playlists.params == "EgIQAw%3D%3D")
        #expect(VideoSearchFilter.shorts.params == "EgIQCQ%3D%3D")
    }
}

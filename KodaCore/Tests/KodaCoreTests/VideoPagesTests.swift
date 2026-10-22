import Foundation
import Testing
@testable import KodaCore

/// Real WEB responses, captured signed out on 22 October 2026 (reduced: tracking fields dropped).
@Suite struct VideoPagesTests {
    @Test func searchReadsVideosAndLeavesShortsOut() throws {
        let results = VideoPages.search(try fixture("web-search"))
        let videos = results.videos.videos
        #expect(videos.count >= 15)
        #expect(videos.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty })
        #expect(videos.contains { $0.channel?.id?.hasPrefix("UC") == true && $0.channel?.avatar != nil })
        #expect(videos.contains { $0.duration != nil && $0.views?.contains("view") == true && $0.published != nil })
        #expect(results.videos.continuation != nil)
    }

    @Test func searchContinuesWithMoreVideos() throws {
        let page = VideoPages.continuation(try fixture("web-search-more"))
        #expect(page.videos.count >= 10)
        #expect(page.continuation != nil)
    }

    @Test func channelSearchReadsHandleAndSubscribers() throws {
        let channels = VideoPages.search(try fixture("web-search-channels")).channels
        let first = try #require(channels.first)
        #expect(first.id == "UCBJycsmduvYEL83R_U4JriQ")
        #expect(first.name == "Marques Brownlee")
        #expect(first.handle == "@mkbhd")
        #expect(first.subscribers?.hasSuffix("subscribers") == true)
        #expect(first.avatar != nil)
    }

    @Test func watchPageReadsTheVideoChannelAndUpNext() throws {
        let page = try #require(VideoPages.watch(try fixture("web-watch"), id: "aqz-KE-bpKQ"))
        #expect(page.video.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(page.video.channel?.name == "Blender")
        #expect(page.video.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.video.channel?.avatar != nil)
        #expect(page.viewCount == "23,457,308 views")
        #expect(page.date == "Nov 10, 2014")
        #expect(page.subscribers == "1.25M subscribers")
        #expect(page.description.hasPrefix("UHD High Frame rate version"))
        #expect(!page.isSubscribed)
        let related = page.related.videos
        #expect(related.count >= 15)
        #expect(!related.contains { $0.id == "aqz-KE-bpKQ" })
        #expect(related.allSatisfy { $0.channel != nil && $0.thumbnail != nil })
        #expect(related.contains { $0.duration != nil && $0.views?.hasSuffix("views") == true })
        #expect(page.related.continuation != nil)
    }

    @Test func channelPageReadsTheHeaderAndItsVideos() throws {
        let page = try #require(VideoPages.channel(try fixture("web-channel-videos"), id: "UCSJ4gkVC6NrvII8umztf0Ow"))
        #expect(page.channel.name == "Lofi Girl")
        #expect(page.channel.handle == "@LofiGirl")
        #expect(page.channel.subscribers == "15.8M subscribers")
        #expect(page.videoCount == "475 videos")
        #expect(page.channel.avatar != nil)
        #expect(page.banner != nil)
        #expect(page.description?.isEmpty == false)
        #expect(page.videos.videos.count == 30)
        // Collaborations name both channels ("Lofi Girl and The Sims").
        #expect(page.videos.videos.allSatisfy { $0.channel?.name.hasPrefix("Lofi Girl") == true })
        #expect(page.videos.continuation != nil)
    }

    @Test func channelVideosContinue() throws {
        let page = VideoPages.continuation(try fixture("web-channel-more"))
        #expect(page.videos.count >= 20)
    }

    @Test func liveLockupsSayWatchingNotViews() throws {
        // The shape of the live rows on a channel's Home tab (22 October 2026), cut down.
        let lockup = JSON(try JSONSerialization.jsonObject(with: Data(#"""
        {"contentType":"LOCKUP_CONTENT_TYPE_VIDEO","contentId":"4xDzrJKXOOY",
         "rendererContext":{"commandContext":{"onTap":{"innertubeCommand":{"watchEndpoint":{"videoId":"4xDzrJKXOOY"}}}}},
         "contentImage":{"thumbnailViewModel":{"image":{"sources":[{"url":"https://i.ytimg.com/vi/4xDzrJKXOOY/hqdefault.jpg","width":336,"height":188}]},
           "overlays":[{"thumbnailBottomOverlayViewModel":{"badges":[{"thumbnailBadgeViewModel":{"text":"LIVE"}}]}}]}},
         "metadata":{"lockupMetadataViewModel":{"title":{"content":"synthwave radio"},
           "metadata":{"contentMetadataViewModel":{"metadataRows":[
             {"metadataParts":[{"text":{"content":"Lofi Girl","commandRuns":[{"onTap":{"innertubeCommand":{"browseEndpoint":{"browseId":"UCSJ4gkVC6NrvII8umztf0Ow"}}}}]}}]},
             {"metadataParts":[{"text":{"content":"2.5K watching"}}]}]}}}}}
        """#.utf8)))
        let video = try #require(VideoPages.video(lockup: lockup))
        #expect(video.isLive)
        #expect(video.views == "2.5K watching")
        #expect(video.published == nil)
        #expect(video.channel?.id == "UCSJ4gkVC6NrvII8umztf0Ow")
        #expect(video.duration == nil)
    }

    @Test func aChannelsOwnRowsTakeTheChannel() throws {
        let page = try #require(VideoPages.channel(try fixture("web-channel-videos"), id: "UCSJ4gkVC6NrvII8umztf0Ow"))
        let first = try #require(page.videos.videos.first)
        #expect(first.views?.hasSuffix("views") == true)
        #expect(first.published?.hasSuffix("ago") == true)
        #expect(first.duration != nil)
    }

    @Test func qualitiesComeFromTheManifestTallestFirst() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=310801,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,FRAME-RATE=30
        a.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4553846,CODECS="avc1.4D4020,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=60
        b.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=395368,CODECS="avc1.4D4015,mp4a.40.2",RESOLUTION=426x240,FRAME-RATE=30
        c.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=1080x1920
        d.m3u8
        """
        #expect(VideoStream.qualities(inMaster: master) == [1080, 720, 240])
    }

    @Test func thumbnailsAreSixteenByNine() {
        let video = Video(id: "abc", title: "T")
        #expect(video.thumbnailURL.absoluteString == "https://i.ytimg.com/vi/abc/hq720.jpg")
        #expect(video.fallbackThumbnailURL.absoluteString == "https://i.ytimg.com/vi/abc/mqdefault.jpg")
        #expect(Video(id: "x", title: "T", channel: ChannelRef(id: nil, name: "C"), views: "1 view").byline == "C · 1 view")
    }
}

@MainActor
@Suite struct WatchedVideosTests {
    @Test func keepsOneEntryPerVideoNewestFirstAndClearsWithHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "koda-watched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = Library(directory: dir)
        library.recordWatch(Video(id: "a", title: "A"))
        library.recordWatch(Video(id: "b", title: "B"))
        library.recordWatch(Video(id: "a", title: "A"))
        library.flush()
        #expect(Library(directory: dir).watched.map(\.id) == ["a", "b"])
        library.clearHistory()
        #expect(library.watched.isEmpty)
    }
}

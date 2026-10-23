import Foundation
import Testing
@testable import KodaCore

/// Likes, subscriptions, comments and channel tabs, from real WEB responses captured signed out
/// on 23 October 2026 (tracking fields dropped).
@Suite struct VideoEngagementTests {
    @Test func watchPageReadsLikesCommentsAndWhatPlaysNext() throws {
        let page = try #require(VideoPages.watch(try fixture("web-watch-engagement"), id: "dQw4w9WgXcQ"))
        #expect(page.likeCounts[.indifferent] == "19M")
        #expect(page.likeCounts[.like] != nil)
        #expect(page.likeStatus == .indifferent)
        #expect(page.commentCount == "2.4M")
        #expect(page.commentsToken != nil)
        #expect(page.autoplayId == "oRdxUFDoQe0")
        #expect(page.next != nil)
        // Signed out the button is drawn unsubscribed for the video's own channel.
        #expect(page.isSubscribed == false)
    }

    @Test func entityKeysNameWhatTheyDescribe() {
        // The watch page's own subscription entity, for Rick Astley's channel.
        let key = "EhhVQ3VBWEZrZ3N3MUw3eGFDZm5kNUpKT3cgMygB"
        #expect(VideoPages.entityKey(key, names: "UCuAXFkgsw1L7xaCfnd5JJOw"))
        #expect(!VideoPages.entityKey(key, names: "UCBJycsmduvYEL83R_U4JriQ"))
        #expect(VideoPages.entityKey("EgtkUXc0dzlXZ1hjUSA-KAE%3D", names: "dQw4w9WgXcQ"))
    }

    @Test func aChannelsSubscriptionIsItsOwnNotAFeaturedOnes() throws {
        func key(_ id: String) -> String {
            var bytes = Data([0x12, 0x18])
            bytes.append(Data(id.utf8))
            bytes.append(Data(" 3(\u{1}".utf8))
            return bytes.base64EncodedString().replacingOccurrences(of: "=", with: "%3D")
        }
        let own = "UCBJycsmduvYEL83R_U4JriQ"
        let featured = "UCuAXFkgsw1L7xaCfnd5JJOw"
        // A featured channel's state comes first in the response, as on a real channel page.
        let root = JSON(try JSONSerialization.jsonObject(with: Data("""
        {"frameworkUpdates":{"entityBatchUpdate":{"mutations":[
          {"payload":{"subscriptionStateEntity":{"key":"\(key(featured))","subscribed":false}}},
          {"payload":{"subscriptionStateEntity":{"key":"\(key(own))","subscribed":true}}}]}}}
        """.utf8)))
        #expect(VideoPages.isSubscribed(root, to: own) == true)
        #expect(VideoPages.isSubscribed(root, to: featured) == false)
        #expect(VideoPages.isSubscribed(root, to: "UCnobodyAtAll000000000000") == nil)
        #expect(VideoPages.isSubscribed(root, to: nil) == nil)
    }

    @Test func channelPageReadsTabsSortsAndTheTick() throws {
        let page = try #require(VideoPages.channel(try fixture("web-channel-videos"), id: "UCSJ4gkVC6NrvII8umztf0Ow"))
        #expect(page.tab == .videos)
        #expect(page.tabs.map(\.kind).contains(.videos))
        #expect(page.sorts.map(\.title) == ["Latest", "Popular", "Oldest"])
        #expect(page.sorts.first?.isSelected == true)
        #expect(page.aboutToken != nil)
        // Signed out nothing says whether the account follows it: unknown, not false.
        #expect(page.isSubscribed == nil)
    }

    @Test func liveTabReadsItsStreams() throws {
        let page = try #require(VideoPages.channel(try fixture("web-channel-live"), id: "UCBJycsmduvYEL83R_U4JriQ"))
        #expect(page.tab == .live)
        #expect(page.isVerified)
        #expect(!page.videos.videos.isEmpty)
        #expect(page.videos.videos.allSatisfy { $0.channel?.name == "Marques Brownlee" })
    }

    @Test func aSortReloadsTheGridAndItsChips() throws {
        let reloaded = VideoPages.reloaded(try fixture("web-channel-sorted"))
        #expect(reloaded.videos.videos.count >= 20)
        #expect(reloaded.videos.continuation != nil)
        #expect(reloaded.sorts.first { $0.isSelected }?.title == "Popular")
    }

    @Test func aboutReadsCountsAndUnwrapsLinks() throws {
        let about = try #require(VideoPages.about(try fixture("web-channel-about")))
        #expect(about.joined == "Joined Mar 21, 2008")
        #expect(about.subscribers?.hasSuffix("subscribers") == true)
        #expect(about.views?.hasSuffix("views") == true)
        #expect(about.country == "United States")
        let twitter = try #require(about.links.first)
        #expect(twitter.title == "Twitter")
        #expect(twitter.url.host()?.contains("twitter.com") == true)
    }

    @Test func commentsReadAuthorsCountsAndTheNextPage() throws {
        let page = VideoPages.comments(try fixture("web-comments"))
        #expect(page.comments.count == 20)
        let first = try #require(page.comments.first)
        #expect(first.author.hasPrefix("@"))
        #expect(!first.text.isEmpty)
        #expect(!first.likes.isEmpty)
        #expect(first.avatar != nil)
        #expect(page.continuation != nil)
    }

    @Test func videoPingsCarryTheWatchedSpan() throws {
        let url = try #require(HistoryPing.videoTrackingURL("https://s.youtube.com/api/stats/watchtime?ns=yt&c=WEB_REMIX&cmt=0",
                                                            cpn: "abc", from: 12, to: 42.5, final: true))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["c"] == "WEB")
        #expect(items["st"] == "12.000")
        #expect(items["et"] == "42.500")
        #expect(items["cmt"] == "42.500")
        #expect(items["final"] == "1")
        #expect(items["ns"] == "yt")
        #expect(HistoryPing.videoTrackingURL("https://evil.example/api/stats/watchtime", cpn: "a", from: 0, to: 1, final: false) == nil)
    }
}

@MainActor
@Suite struct VideoProgressTests {
    @Test func keepsWhereAWatchedVideoGotAndResumesOnlyMidway() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "koda-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = Library(directory: dir)
        // Not watched (history paused): nothing kept.
        library.setProgress(100, of: 600, for: "a")
        #expect(library.videoProgress["a"] == nil)
        library.recordWatch(Video(id: "a", title: "A"))
        library.setProgress(100, of: 600, for: "a")
        library.flush()
        let reopened = Library(directory: dir)
        #expect(reopened.videoProgress["a"]?.resumeAt == 100)
        #expect(VideoProgress(position: 4, duration: 600).resumeAt == nil)
        #expect(VideoProgress(position: 590, duration: 600).resumeAt == nil)
        library.removeWatched("a")
        #expect(library.videoProgress["a"] == nil)
    }
}

/// Explore, playlists and the guide, from WEB responses captured signed out on 23 October 2026.
@Suite struct VideoBrowseTests {
    @Test func topicPagesReadTheirShelves() throws {
        let music = VideoPages.shelves(try fixture("web-topic-music"))
        // The first two shelves are stations (mixes), not videos: left out.
        #expect(music.count >= 3)
        #expect(music.first?.title == "Artist On The Rise Trending")
        #expect(music.allSatisfy { !$0.videos.isEmpty })
        let news = VideoPages.shelves(try fixture("web-topic-news"))
        // "Latest news posts" holds posts, not videos: left out.
        #expect(!news.contains { $0.title == "Latest news posts" })
        #expect(news.count >= 3)
    }

    @Test func playlistsReadTheirVideosAndTheNewContinuation() throws {
        let page = try #require(VideoPages.playlist(try fixture("web-playlist")))
        #expect(page.title == "Popular Music Videos")
        #expect(page.videos.videos.count == 100)
        #expect(page.videos.videos.allSatisfy { $0.channel != nil })
        #expect(page.videos.continuation != nil)
    }

    @Test func watchLaterReadsItsOlderRows() throws {
        // Watch Later's shape signed in, cut down and with made-up videos: playlistVideoRenderer
        // rows in a playlistVideoListRenderer, a deleted video among them.
        let page = try #require(VideoPages.playlist(try fixture("watch-later")))
        #expect(page.title == "Watch later")
        let videos = page.videos.videos
        #expect(videos.map(\.id) == ["aaaaaaaaaa1", "bbbbbbbbbb2"], "the deleted video is left out")
        #expect(videos[0].title == "Saved Video 1")
        #expect(videos[0].channel == ChannelRef(id: "UCchannel1", name: "Channel 1"))
        #expect(videos[0].duration == 5288)
        #expect(videos[0].views == "150K views")
        #expect(videos[0].published == "1 day ago")
        #expect(videos[0].thumbnail != nil)
        #expect(page.videos.continuation == "WL-NEXT-PAGE")
    }

    @Test func sidebarChannelsLeadWithTheLatestUploads() {
        // The guide is A to Z; the feed is newest first, a channel at most once in the order.
        let a = ChannelRef(id: "UCa", name: "Apple"), b = ChannelRef(id: "UCb", name: "Billie"),
            c = ChannelRef(id: "UCc", name: "Cats"), d = ChannelRef(id: "UCd", name: "Dune")
        let feed = [Video(id: "1", title: "", channel: c), Video(id: "2", title: "", channel: a),
                    Video(id: "3", title: "", channel: c), Video(id: "4", title: "", channel: ChannelRef(id: nil, name: "Dune"))]
        #expect(ChannelRef.byLatestUpload([a, b, c, d], feed: feed).map(\.name) == ["Cats", "Apple", "Dune", "Billie"])
        #expect(ChannelRef.byLatestUpload([a, b], feed: []).map(\.name) == ["Apple", "Billie"])
    }

    @Test func theGuideListsSubscribedChannelsOnly() throws {
        // The guide's shape for a signed-in account, cut down: the Explore section's Music
        // entry is a channel too, and isn't a subscription.
        let root = JSON(try JSONSerialization.jsonObject(with: Data(#"""
        {"items":[
          {"guideSectionRenderer":{"items":[{"guideEntryRenderer":{"formattedTitle":{"simpleText":"Music"},
            "navigationEndpoint":{"browseEndpoint":{"browseId":"UC-9-kyTW8ZkZNDHQJ6FgpwQ"}}}}]}},
          {"guideSubscriptionsSectionRenderer":{"items":[
            {"guideEntryRenderer":{"formattedTitle":{"simpleText":"Marques Brownlee"},
              "navigationEndpoint":{"browseEndpoint":{"browseId":"UCBJycsmduvYEL83R_U4JriQ"}},
              "thumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/a=s88","width":88,"height":88}]}}},
            {"guideEntryRenderer":{"formattedTitle":{"simpleText":"Show more"}}}]}}]}
        """#.utf8)))
        let channels = VideoPages.subscriptions(root)
        #expect(channels.map(\.name) == ["Marques Brownlee"])
        #expect(channels.first?.avatar != nil)
    }
}

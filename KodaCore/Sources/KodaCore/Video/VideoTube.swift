import Foundation

/// YouTube itself, beside YouTube Music: video feeds, search, watch pages, channels and streams,
/// on the WEB client at www.youtube.com, signed in as the active account when there is one.
extension YouTubeMusic {
    /// Where a list came from, which decides the endpoint its continuation goes to.
    public enum VideoListSource: Sendable {
        case browse, search, next
    }

    /// The account's Home. Signed out YouTube sends an empty Home ("search to get started"), so
    /// the app builds its own then (Up Next of what was watched, or a search).
    public func videoHome() async throws -> VideoPage {
        VideoPages.feed(try await api.web("browse", ["browseId": "FEwhat_to_watch"], signing: .required))
    }

    /// The latest from the account's subscriptions.
    public func videoSubscriptions() async throws -> VideoPage {
        VideoPages.feed(try await api.web("browse", ["browseId": "FEsubscriptions"], signing: .required))
    }

    /// Videos and the channels that match, best first. Shorts are left out.
    public func searchVideos(_ query: String) async throws -> VideoSearchResults {
        VideoPages.search(try await api.web("search", ["query": query]))
    }

    /// The next page of a list.
    public func moreVideos(_ continuation: String, from source: VideoListSource) async throws -> VideoPage {
        let endpoint = switch source {
        case .browse: "browse"
        case .search: "search"
        case .next: "next"
        }
        return VideoPages.continuation(try await api.web(endpoint, ["continuation": continuation]))
    }

    /// Everything under the player: the video's details, its channel and Up Next.
    public func watchPage(_ videoId: String) async throws -> WatchPage {
        guard let page = VideoPages.watch(try await api.web("next", ["videoId": videoId]), id: videoId) else {
            throw MusicError.badResponse(200)
        }
        return page
    }

    /// A channel's header and one of its tabs: the Videos tab, newest first, unless `tab` (from
    /// an earlier page's `tabs`) says otherwise.
    public func channel(_ channelId: String, tab: ChannelTab? = nil) async throws -> ChannelPage {
        // The Videos tab's params [verified October 2026].
        let root = try await api.web("browse", ["browseId": channelId, "params": tab?.params ?? "EgZ2aWRlb3PyBgQKAjoA"])
        guard let page = VideoPages.channel(root, id: channelId) else { throw MusicError.badResponse(200) }
        return page
    }

    /// A channel tab's videos in another order (a `ChannelSort`), and the orders as now chosen.
    public func channelVideos(sortedBy sort: ChannelSort, channel: ChannelRef) async throws -> (videos: VideoPage, sorts: [ChannelSort]) {
        let reloaded = VideoPages.reloaded(try await api.web("browse", ["continuation": sort.token]))
        guard !reloaded.videos.videos.isEmpty else { throw MusicError.badResponse(200) }
        return (VideoPages.withChannel(reloaded.videos, channel), reloaded.sorts)
    }

    /// What a channel says about itself: the About panel.
    public func channelAbout(_ token: String) async throws -> ChannelAbout {
        guard let about = VideoPages.about(try await api.web("browse", ["continuation": token])) else { throw MusicError.badResponse(200) }
        return about
    }

    /// A page of a video's comments, top first: the watch page's `commentsToken`, then each
    /// page's `continuation`.
    public func comments(_ token: String) async throws -> CommentsPage {
        VideoPages.comments(try await api.web("next", ["continuation": token]))
    }

    /// Like, dislike or clear the account's rating of a video, on YouTube itself (a like there
    /// is a like in YouTube Music too, for a song).
    public func rate(videoId: String, _ status: LikeStatus) async throws {
        let endpoint = switch status {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .indifferent: "like/removelike"
        }
        _ = try await api.web(endpoint, ["target": ["videoId": videoId]], signing: .required)
    }

    /// Subscribe to a channel on YouTube itself, or unsubscribe.
    public func setSubscribedOnYouTube(channelId: String, subscribed: Bool) async throws {
        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        _ = try await api.web(endpoint, ["channelIds": [channelId]], signing: .required)
    }

    public func videoStream(_ videoId: String) async throws -> VideoStream {
        try await streams.resolveVideo(videoId)
    }
}

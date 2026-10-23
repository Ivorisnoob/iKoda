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

    /// Everything under the player: the video's details, its channel and Up Next. Kept ten
    /// minutes per profile: going back to a video, or opening one a signed-out Home was built
    /// from, asks YouTube nothing. (Ratings and subscriptions made since are the app's to apply.)
    public func watchPage(_ videoId: String) async throws -> WatchPage {
        try await page("watch|\(videoId)") { [api] in
            guard let page = VideoPages.watch(try await api.web("next", ["videoId": videoId]), id: videoId) else {
                throw MusicError.badResponse(200)
            }
            return page
        }
    }

    /// A channel's header and one of its tabs: the Videos tab, newest first, unless `tab` (from
    /// an earlier page's `tabs`) says otherwise.
    public func channel(_ channelId: String, tab: ChannelTab? = nil, fresh: Bool = false) async throws -> ChannelPage {
        // The Videos tab's params [verified October 2026].
        let params = tab?.params ?? "EgZ2aWRlb3PyBgQKAjoA"
        let load: @Sendable () async throws -> ChannelPage = { [api] in
            let root = try await api.web("browse", ["browseId": channelId, "params": params])
            guard let page = VideoPages.channel(root, id: channelId) else { throw MusicError.badResponse(200) }
            return page
        }
        // Pull to refresh asks again; otherwise a channel seen in the last ten minutes is reused.
        return fresh ? try await load() : try await page("channel|\(channelId)|\(params)", load: load)
    }

    /// A topic page's shelves: Music, Live, News, Sports, Learning (`ExploreTopic`).
    public func explore(_ browseId: String) async throws -> [VideoShelf] {
        try await page("explore|\(browseId)") { [api] in
            let shelves = VideoPages.shelves(try await api.web("browse", ["browseId": browseId]))
            guard !shelves.isEmpty else { throw MusicError.badResponse(200) }
            return shelves
        }
    }

    /// A playlist of videos: `WL` (Watch Later) and `LL` (Liked videos) are the account's own and
    /// need it signed in. Never cached: they change as the listener uses them.
    public func videoPlaylist(_ playlistId: String) async throws -> VideoPlaylistPage {
        let signing: InnerTube.Signing = ["WL", "LL"].contains(playlistId) ? .required : .ifSignedIn
        guard let page = VideoPages.playlist(try await api.web("browse", ["browseId": "VL" + playlistId], signing: signing)) else {
            throw MusicError.badResponse(200)
        }
        return page
    }

    /// The channels the signed-in account subscribes to, from YouTube's sidebar (`guide`): one
    /// call, kept ten minutes.
    public func subscribedChannels() async throws -> [ChannelRef] {
        try await page("guide") { [api] in VideoPages.subscriptions(try await api.web("guide", [:], signing: .required)) }
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

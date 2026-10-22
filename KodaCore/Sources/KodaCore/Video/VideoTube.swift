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

    /// A channel's header and its Videos tab, newest first.
    public func channel(_ channelId: String) async throws -> ChannelPage {
        // The Videos tab's params [verified October 2026].
        let root = try await api.web("browse", ["browseId": channelId, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        guard let page = VideoPages.channel(root, id: channelId) else { throw MusicError.badResponse(200) }
        return page
    }

    public func videoStream(_ videoId: String) async throws -> VideoStream {
        try await streams.resolveVideo(videoId)
    }
}

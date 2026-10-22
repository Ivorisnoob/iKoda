import Foundation

/// A YouTube video, as feeds, search, channels and Up Next list it.
public struct Video: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var channel: ChannelRef?
    /// The response's own thumbnail; `thumbnailURL` is usually the sharper one to show.
    public var thumbnail: Artwork?
    public var duration: TimeInterval?
    /// "1.2M views", or "2.5K watching" while live.
    public var views: String?
    /// "3 days ago".
    public var published: String?
    public var isLive: Bool

    public init(id: String, title: String, channel: ChannelRef? = nil, thumbnail: Artwork? = nil, duration: TimeInterval? = nil,
                views: String? = nil, published: String? = nil, isLive: Bool = false) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnail = thumbnail
        self.duration = duration
        self.views = views
        self.published = published
        self.isLive = isLive
    }

    /// The 1280×720 frame YouTube keeps for nearly every video; `fallbackThumbnailURL` (320×180)
    /// exists for all of them. Both 16:9, unlike the letterboxed `hqdefault`.
    public var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hq720.jpg")! }
    public var fallbackThumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }

    /// "Channel · 1.2M views · 3 days ago", leaving out what isn't known.
    public var byline: String {
        [channel?.name, views, published].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// The channel a video is from.
public struct ChannelRef: Hashable, Codable, Sendable {
    /// A `UC…` id; nil when the response named the channel without a link.
    public var id: String?
    public var name: String
    public var avatar: Artwork?

    public init(id: String?, name: String, avatar: Artwork? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// A channel as search lists it.
public struct ChannelSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// "@mkbhd".
    public var handle: String?
    /// "21.4M subscribers".
    public var subscribers: String?
    public var avatar: Artwork?

    public init(id: String, name: String, handle: String? = nil, subscribers: String? = nil, avatar: Artwork? = nil) {
        self.id = id
        self.name = name
        self.handle = handle
        self.subscribers = subscribers
        self.avatar = avatar
    }

    public var ref: ChannelRef { ChannelRef(id: id, name: name, avatar: avatar) }
}

/// One page of a list of videos, and the token for the next.
public struct VideoPage: Sendable {
    public var videos: [Video]
    public var continuation: String?

    public init(videos: [Video] = [], continuation: String? = nil) {
        self.videos = videos
        self.continuation = continuation
    }
}

public struct VideoSearchResults: Sendable {
    public var channels: [ChannelSummary]
    public var videos: VideoPage

    public init(channels: [ChannelSummary], videos: VideoPage) {
        self.channels = channels
        self.videos = videos
    }
}

/// What the watch page shows under the player.
public struct WatchPage: Sendable {
    public var video: Video
    /// "23,457,308 views".
    public var viewCount: String?
    /// "Nov 10, 2014".
    public var date: String?
    public var description: String
    public var subscribers: String?
    public var isSubscribed: Bool
    public var related: VideoPage
}

public struct ChannelPage: Sendable {
    public var channel: ChannelSummary
    public var banner: Artwork?
    public var description: String?
    /// "475 videos".
    public var videoCount: String?
    public var isSubscribed: Bool
    /// The Videos tab, newest first.
    public var videos: VideoPage

    public init(channel: ChannelSummary, banner: Artwork?, description: String?, videoCount: String?, isSubscribed: Bool, videos: VideoPage) {
        self.channel = channel
        self.banner = banner
        self.description = description
        self.videoCount = videoCount
        self.isSubscribed = isSubscribed
        self.videos = videos
    }
}

/// A video's stream: YouTube's HLS manifest, which AVPlayer plays as it is, every quality from
/// 144p up, switching with the connection.
public struct VideoStream: Sendable, Equatable {
    public var videoId: String
    public var url: URL
    public var isLive: Bool
    public var expiresAt: Date?

    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 10 * 60
    }
}

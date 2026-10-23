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

/// The account's rating of a video, as YouTube's like and dislike buttons draw it.
public enum LikeStatus: String, Sendable, Codable {
    case like, dislike, indifferent
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
    /// The account follows the channel; nil when the response doesn't say (signed out).
    public var isSubscribed: Bool?
    /// The like count YouTube would draw for each rating ("19M"), so liking moves it by one
    /// as the site does. Empty when the creator hides the count.
    public var likeCounts: [LikeStatus: String]
    /// The account's own rating; `.indifferent` signed out.
    public var likeStatus: LikeStatus
    /// "2.4M"; nil with comments off.
    public var commentCount: String?
    /// Opens the comments, newest page first; nil with comments off.
    public var commentsToken: String?
    /// The video YouTube would play next.
    public var autoplayId: String?
    public var related: VideoPage

    /// Up Next's first choice: YouTube's own autoplay pick when it's in the list, else its top.
    public var next: Video? {
        related.videos.first { $0.id == autoplayId } ?? related.videos.first
    }
}

/// One of a channel's tabs that Koda can show.
public enum ChannelTabKind: String, Sendable, CaseIterable {
    case videos, live

    public var title: String { self == .videos ? "Videos" : "Live" }
}

public struct ChannelTab: Sendable, Hashable {
    public var kind: ChannelTabKind
    /// The browse `params` that open it, as the response gave them.
    public var params: String
}

/// An order a channel's videos can be listed in: Latest, Popular, Oldest.
public struct ChannelSort: Sendable, Hashable, Identifiable {
    public var title: String
    public var token: String
    public var isSelected: Bool
    public var id: String { title }
}

public struct ChannelPage: Sendable {
    public var channel: ChannelSummary
    public var banner: Artwork?
    public var description: String?
    /// "475 videos".
    public var videoCount: String?
    /// The account follows it; nil when the response doesn't say (signed out, or a shape
    /// Koda doesn't know), never a guessed false.
    public var isSubscribed: Bool?
    public var isVerified: Bool
    /// The tabs it has that Koda shows, in YouTube's order.
    public var tabs: [ChannelTab]
    /// The open tab.
    public var tab: ChannelTabKind
    /// The open tab's orders; empty when it has none.
    public var sorts: [ChannelSort]
    /// Opens the About panel.
    public var aboutToken: String?
    /// The open tab's videos.
    public var videos: VideoPage

    public init(channel: ChannelSummary, banner: Artwork?, description: String?, videoCount: String?, isSubscribed: Bool?,
                isVerified: Bool = false, tabs: [ChannelTab] = [], tab: ChannelTabKind = .videos, sorts: [ChannelSort] = [],
                aboutToken: String? = nil, videos: VideoPage) {
        self.channel = channel
        self.banner = banner
        self.description = description
        self.videoCount = videoCount
        self.isSubscribed = isSubscribed
        self.isVerified = isVerified
        self.tabs = tabs
        self.tab = tab
        self.sorts = sorts
        self.aboutToken = aboutToken
        self.videos = videos
    }
}

/// A channel's About panel.
public struct ChannelAbout: Sendable {
    public var description: String?
    public var country: String?
    /// "21.4M subscribers".
    public var subscribers: String?
    /// "5,818,929,559 views".
    public var views: String?
    /// "Joined Mar 21, 2008".
    public var joined: String?
    /// "1,861 videos".
    public var videoCount: String?
    public var links: [ChannelLink]

    public init(description: String?, country: String?, subscribers: String?, views: String?, joined: String?,
                videoCount: String?, links: [ChannelLink]) {
        self.description = description
        self.country = country
        self.subscribers = subscribers
        self.views = views
        self.joined = joined
        self.videoCount = videoCount
        self.links = links
    }
}

/// A link a channel lists about itself, its URL unwrapped from YouTube's redirect.
public struct ChannelLink: Sendable, Hashable, Identifiable {
    public var title: String
    /// What the panel shows: "twitter.com/MKBHD".
    public var label: String
    public var url: URL
    public var id: URL { url }
}

/// A comment under a video.
public struct VideoComment: Sendable, Identifiable, Hashable {
    public var id: String
    public var author: String
    public var authorChannelId: String?
    public var avatar: URL?
    public var text: String
    /// "6 years ago".
    public var published: String
    /// "292K"; empty with none.
    public var likes: String
    /// "711"; empty with none.
    public var replies: String
    public var isCreator: Bool
    public var isVerified: Bool

    public init(id: String, author: String, authorChannelId: String?, avatar: URL?, text: String, published: String,
                likes: String, replies: String, isCreator: Bool, isVerified: Bool) {
        self.id = id
        self.author = author
        self.authorChannelId = authorChannelId
        self.avatar = avatar
        self.text = text
        self.published = published
        self.likes = likes
        self.replies = replies
        self.isCreator = isCreator
        self.isVerified = isVerified
    }
}

public struct CommentsPage: Sendable {
    public var comments: [VideoComment]
    public var continuation: String?

    public init(comments: [VideoComment] = [], continuation: String? = nil) {
        self.comments = comments
        self.continuation = continuation
    }
}

/// A video's stream: YouTube's HLS manifest, which AVPlayer plays as it is, every quality from
/// 144p up, switching with the connection.
public struct VideoStream: Sendable, Equatable {
    public var videoId: String
    public var url: URL
    public var isLive: Bool
    public var expiresAt: Date?
    /// The picture heights the manifest offers, tallest first (2160, 1440, 1080…): the Quality menu.
    public var qualities: [Int] = []

    /// The heights in an HLS master playlist's `RESOLUTION=WxH` attributes, each once, tallest first.
    static func qualities(inMaster text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"RESOLUTION=(\d+)x(\d+)"#) else { return [] }
        let heights = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Int? in
            guard let w = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let h = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
            // A portrait video's lines are its width.
            return min(w, h)
        }
        return Array(Set(heights)).sorted(by: >)
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 10 * 60
    }
}

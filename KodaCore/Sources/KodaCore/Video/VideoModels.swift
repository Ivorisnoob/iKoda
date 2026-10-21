import Foundation

// MARK: - Video Models

/// A single YouTube video item in the video mode.
public struct VideoItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String                 // the video id
    public var title: String
    public var channel: String
    public var channelId: String?
    public var thumbnail: Artwork?
    public var duration: TimeInterval?
    public var viewCountText: String?
    public var publishedText: String?
    public var isLive: Bool
    public var isShort: Bool

    public init(
        id: String,
        title: String,
        channel: String,
        channelId: String? = nil,
        thumbnail: Artwork? = nil,
        duration: TimeInterval? = nil,
        viewCountText: String? = nil,
        publishedText: String? = nil,
        isLive: Bool = false,
        isShort: Bool = false
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.channelId = channelId
        self.thumbnail = thumbnail
        self.duration = duration
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.isLive = isLive
        self.isShort = isShort
    }
}

/// A YouTube creator or user channel.
public struct VideoChannel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var avatar: Artwork?
    public var subscriberText: String?

    public init(
        id: String,
        name: String,
        avatar: Artwork? = nil,
        subscriberText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.subscriberText = subscriberText
    }
}

/// A video playlist summary item.
public struct VideoPlaylistSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var thumbnail: Artwork?
    public var itemCount: Int?

    public init(
        id: String,
        title: String,
        channel: String? = nil,
        thumbnail: Artwork? = nil,
        itemCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnail = thumbnail
        self.itemCount = itemCount
    }
}

/// A titled collection of videos in a feed.
public struct VideoShelf: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var items: [VideoItem]

    public init(id: String, title: String, items: [VideoItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// The browse feed of video shelves and optional continuation.
public struct VideoFeed: Sendable {
    public var shelves: [VideoShelf]
    public var continuation: String?

    public init(shelves: [VideoShelf] = [], continuation: String? = nil) {
        self.shelves = shelves
        self.continuation = continuation
    }
}

/// Multi-category search results from YouTube.
public struct VideoSearchResults: Sendable {
    public var videos: [VideoItem]
    public var channels: [VideoChannel]
    public var playlists: [VideoPlaylistSummary]
    public var continuation: String?

    public init(
        videos: [VideoItem] = [],
        channels: [VideoChannel] = [],
        playlists: [VideoPlaylistSummary] = [],
        continuation: String? = nil
    ) {
        self.videos = videos
        self.channels = channels
        self.playlists = playlists
        self.continuation = continuation
    }

    public var isEmpty: Bool {
        videos.isEmpty && channels.isEmpty && playlists.isEmpty
    }

    public static let empty = VideoSearchResults()
}

/// Filter chips for YouTube video searches.
public enum VideoSearchFilter: String, CaseIterable, Sendable {
    case all, videos, channels, playlists, shorts

    /// The `params` the search chips send. [verified October 2026]
    var params: String? {
        switch self {
        case .all: nil
        case .videos: "EgIQAQ%3D%3D"
        case .channels: "EgIQAg%3D%3D"
        case .playlists: "EgIQAw%3D%3D"
        case .shorts: "EgIQCQ%3D%3D"
        }
    }
}

/// A playlist page containing its summary metadata, description, and videos.
public struct VideoPlaylistPage: Sendable {
    public var playlist: VideoPlaylistSummary
    public var description: String?
    public var items: [VideoItem]
    public var continuation: String?

    public init(
        playlist: VideoPlaylistSummary,
        description: String? = nil,
        items: [VideoItem] = [],
        continuation: String? = nil
    ) {
        self.playlist = playlist
        self.description = description
        self.items = items
        self.continuation = continuation
    }
}

/// A watch page's metadata, channel info, description, and up-next queue.
public struct VideoWatchPage: Sendable {
    public var video: VideoItem
    public var channel: VideoChannel
    public var description: String?
    public var viewCountText: String?
    public var publishedText: String?
    public var upNext: [VideoItem]
    public var continuation: String?

    public init(
        video: VideoItem,
        channel: VideoChannel,
        description: String? = nil,
        viewCountText: String? = nil,
        publishedText: String? = nil,
        upNext: [VideoItem] = [],
        continuation: String? = nil
    ) {
        self.video = video
        self.channel = channel
        self.description = description
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.upNext = upNext
        self.continuation = continuation
    }
}

/// The ladder the player offers. `automatic` lets AVPlayer decide.
public enum VideoQuality: String, CaseIterable, Sendable {
    case automatic, p360, p480, p720, p1080

    /// The peak bitrate AVPlayer is allowed, in bits per second.
    /// 0.0 indicates that no peak bitrate limit is enforced.
    public var peakBitRate: Double {
        switch self {
        case .automatic: 0.0
        case .p360: 800_000.0
        case .p480: 1_500_000.0
        case .p720: 3_000_000.0
        case .p1080: 6_000_000.0
        }
    }

    /// The largest height AVPlayer may pick, in points.
    /// 0 indicates uncapped (no maximum height limit).
    public var maxHeight: Int {
        switch self {
        case .automatic: 0
        case .p360: 360
        case .p480: 480
        case .p720: 720
        case .p1080: 1080
        }
    }
}

/// Where a video's picture comes from.
public struct VideoStream: Sendable, Equatable {
    public var videoId: String
    public var url: URL
    public var isHLS: Bool
    public var userAgent: String
    public var duration: TimeInterval?
    public var expiresAt: Date?

    public init(
        videoId: String,
        url: URL,
        isHLS: Bool,
        userAgent: String,
        duration: TimeInterval? = nil,
        expiresAt: Date? = nil
    ) {
        self.videoId = videoId
        self.url = url
        self.isHLS = isHLS
        self.userAgent = userAgent
        self.duration = duration
        self.expiresAt = expiresAt
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 10 * 60
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

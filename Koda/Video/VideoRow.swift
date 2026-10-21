import KodaCore
import SwiftUI

/// A video's thumbnail is 16:9, cropped to fill, never letterboxed, with the
/// duration sitting on it the way YouTube puts it.
struct VideoThumbnail: View {
    var artwork: Artwork?
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.quaternary)
            if let artwork {
                ArtworkView(artwork: artwork, size: 160, cornerRadius: 0, fillsFrame: true)
            } else {
                Image(systemName: "play.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A video in a list: 16:9 thumbnail, title, channel, and a duration badge.
struct VideoRow: View {
    let video: VideoItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    VideoThumbnail(artwork: video.thumbnail, cornerRadius: 8)
                        .frame(width: 140, height: 79)
                    if let duration = video.duration {
                        Text(format(duration))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4, style: .continuous))
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(video.channel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let views = video.viewCountText {
                        Text(views)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(seconds.rounded(.down))
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// A video as a card in a shelf: 16:9 thumbnail, title and channel.
struct VideoCard: View {
    let video: VideoItem
    var width: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                VideoThumbnail(artwork: video.thumbnail, cornerRadius: 10)
                    .frame(width: width, height: width * 9 / 16)
                if let duration = video.duration {
                    Text(format(duration))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(video.channel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(seconds.rounded(.down))
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

extension VideoItem {
    static func placeholders(_ count: Int) -> [VideoItem] {
        (0..<count).map { i in
            VideoItem(id: "placeholder-\(i)", title: "Video title", channel: "Channel name",
                     channelId: nil, thumbnail: nil, duration: 180,
                     viewCountText: nil, publishedText: nil, isLive: false, isShort: false)
        }
    }
}

extension VideoFeed {
    static let placeholder = VideoFeed(shelves: (0..<3).map { i in
        VideoShelf(id: "placeholder-shelf-\(i)", title: "Videos", items: VideoItem.placeholders(6))
    }, continuation: nil)
}

extension VideoSearchResults {
    static let placeholder = VideoSearchResults(videos: VideoItem.placeholders(8), channels: [], playlists: [], continuation: nil)
}

extension VideoPlaylistPage {
    static let placeholder = VideoPlaylistPage(
        playlist: VideoPlaylistSummary(id: "placeholder", title: "Playlist", channel: "Channel", thumbnail: nil, itemCount: 8),
        description: nil,
        items: VideoItem.placeholders(8),
        continuation: nil
    )
}

extension VideoWatchPage {
    static let placeholder = VideoWatchPage(
        video: VideoItem.placeholders(1).first!,
        channel: VideoChannel(id: "placeholder", name: "Channel", avatar: nil, subscriberText: nil),
        description: "A short description of the video.",
        viewCountText: "1,000 views",
        publishedText: "1 day ago",
        upNext: VideoItem.placeholders(6),
        continuation: nil
    )
}

extension VideoQuality {
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .p360: "360p"
        case .p480: "480p"
        case .p720: "720p"
        case .p1080: "1080p"
        }
    }
}

extension VideoSearchFilter {
    var title: String {
        switch self {
        case .all: "All"
        case .videos: "Videos"
        case .channels: "Channels"
        case .playlists: "Playlists"
        case .shorts: "Shorts"
        }
    }
}

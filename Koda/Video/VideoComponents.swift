import KodaCore
import SwiftUI
import UIKit

/// A video's 16:9 frame: YouTube's 1280-wide image, or the 320-wide one every video has when
/// that's missing. Laid out by a shape so the image never sets its own size.
struct VideoThumbnail: View {
    let video: Video
    var cornerRadius: CGFloat = 12
    /// The width it's drawn at, for the pixels to load.
    var width: CGFloat = 400
    /// The bar showing how far it was watched; off inside the player, which has its own.
    var showsProgress = true
    @Environment(\.displayScale) private var scale
    @Environment(Library.self) private var library
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) { progress }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) { badge }
            .task(id: video.id) {
                guard !video.id.hasPrefix("placeholder") else { return }
                let pixels = Int((width * scale).rounded(.up))
                // The sharp frame only where it's drawn big enough to need it.
                let urls = pixels > 400 ? [video.thumbnailURL, video.fallbackThumbnailURL] : [video.fallbackThumbnailURL, video.thumbnailURL]
                for url in urls {
                    if let hit = ImagePipeline.shared.cached(url, pixels: pixels) {
                        image = hit
                        return
                    }
                    if let loaded = await ImagePipeline.shared.image(url, pixels: pixels) {
                        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                        return
                    }
                }
            }
            .accessibilityHidden(true)
    }

    /// How far it was watched, along the foot of the frame, as YouTube draws it.
    @ViewBuilder
    private var progress: some View {
        if showsProgress, !video.isLive, let fraction = library.videoProgress[video.id]?.fraction, fraction > 0.01 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.35))
                    Rectangle().fill(.red).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if video.isLive {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.red, in: .capsule)
                .foregroundStyle(.white)
                .padding(6)
        } else if let duration = video.duration {
            Text(Duration.seconds(duration).formatted(duration >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond)))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 5, style: .continuous))
                .foregroundStyle(.white)
                .padding(6)
                .padding(.bottom, library.videoProgress[video.id] == nil ? 0 : 3)
        }
    }
}

/// A channel's round picture.
struct ChannelAvatar: View {
    let avatar: Artwork?
    var size: CGFloat = 36

    var body: some View {
        ArtworkView(artwork: avatar, size: size, circle: true)
            .frame(width: size, height: size)
    }
}

/// A video in a feed or grid: the frame, then the channel's picture beside the title and byline.
struct VideoCard: View {
    let video: Video
    var width: CGFloat = 400
    var showsChannel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoThumbnail(video: video, width: width)
            HStack(alignment: .top, spacing: 10) {
                if showsChannel {
                    ChannelAvatar(avatar: video.channel?.avatar, size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        // A grid cell otherwise held the title to one line and an ellipsis.
                        .fixedSize(horizontal: false, vertical: true)
                    Text(showsChannel ? video.byline : [video.views, video.published].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(video.title), \(video.byline)")
    }
}

/// A video in a list beside other things: a small frame and the details to its right (Up Next).
struct VideoRow: View {
    let video: Video
    var thumbnailWidth: CGFloat = 156

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoThumbnail(video: video, cornerRadius: 9, width: thumbnailWidth)
                .frame(width: thumbnailWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let channel = video.channel?.name {
                    Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                let stats = [video.views, video.published].compactMap { $0 }.joined(separator: " · ")
                if !stats.isEmpty {
                    Text(stats).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// What a video's context menu offers wherever it's listed: sharing it and going to its channel.
struct VideoMenuItems: View {
    let video: Video
    @Environment(AppModel.self) private var app

    var body: some View {
        ShareLink(item: video.watchURL, subject: Text(video.title)) { Label("Share", systemImage: "square.and.arrow.up") }
        if let channel = video.channel, let id = channel.id {
            Button("Go to Channel", systemImage: "person.crop.square") { app.open(.channel(id: id, name: channel.name)) }
        }
    }
}

extension Video {
    /// The stand-ins a feed draws, redacted, while it loads.
    static let placeholders = (0..<8).map {
        Video(id: "placeholder-\($0)", title: "A video title that runs to two lines", channel: ChannelRef(id: nil, name: "Channel name"),
              views: "1.2M views", published: "2 days ago")
    }
}

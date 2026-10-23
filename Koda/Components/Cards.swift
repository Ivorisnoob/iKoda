import KodaCore
import SwiftUI

/// An album, playlist or song as a square card in a shelf.
struct CoverCard<Cover: View>: View {
    let title: String
    let subtitle: String?
    var width: CGFloat
    let cover: Cover

    /// A card with a cover drawn by the caller, such as a playlist's mosaic, at `width` square.
    init(title: String, subtitle: String?, width: CGFloat = 156, @ViewBuilder cover: () -> Cover) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.cover = cover()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }
}

extension CoverCard where Cover == ArtworkView {
    init(artwork: Artwork?, title: String, subtitle: String?, width: CGFloat = 156) {
        self.init(title: title, subtitle: subtitle, width: width) {
            ArtworkView(artwork: artwork, size: width, cornerRadius: 10)
        }
    }
}

/// An artist as a round portrait with their name under it.
struct ArtistCard: View {
    let artist: ArtistSummary
    var width: CGFloat = 120

    var body: some View {
        VStack(spacing: 8) {
            ArtworkView(artwork: artist.artwork, size: width, circle: true)
            Text(artist.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: width)
        .contentShape(.rect)
    }
}

extension AlbumSummary {
    /// "Album · 2020", "Single · The Weeknd".
    var cardSubtitle: String {
        [kind?.rawValue, artistLine.isEmpty ? year.map(String.init) : artistLine].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Any music item as the card a shelf shows for it. Songs play; everything else opens.
struct ItemCard: View {
    let item: MusicItem
    var width: CGFloat = 156
    var onPlay: (Song) -> Void

    var body: some View {
        switch item {
        case .song(let song):
            Button { onPlay(song) } label: {
                CoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine, width: width)
            }
            .buttonStyle(.plain)
            .contextMenu { SongMenuItems(song: song) } preview: { SongPreview(song: song) }
        case .album(let album):
            NavigationLink(value: Route.album(album)) {
                CoverCard(artwork: album.artwork, title: album.title, subtitle: album.cardSubtitle, width: width)
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlist)) {
                CoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.subtitle, width: width)
            }
            .buttonStyle(.plain)
        case .artist(let artist):
            NavigationLink(value: Route.artist(artist)) {
                ArtistCard(artist: artist, width: width * 0.8)
            }
            .buttonStyle(.plain)
        }
    }
}

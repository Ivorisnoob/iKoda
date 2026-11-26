import KodaCore
import SwiftUI

/// An album, playlist or song as a square card in a shelf.
struct CoverCard<Cover: View>: View {
    let title: String
    let subtitle: String?
    var width: CGFloat
    /// The page the card opens, which zooms out of its cover.
    var zoom: Route?
    let cover: Cover

    /// A card with a cover drawn by the caller, such as a playlist's mosaic, at `width` square.
    init(title: String, subtitle: String?, width: CGFloat = 156, zoom: Route? = nil, @ViewBuilder cover: () -> Cover) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.zoom = zoom
        self.cover = cover()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .zoomSource(zoom)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.scaled(.subheadline).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.scaled(.footnote))
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
    init(artwork: Artwork?, title: String, subtitle: String?, width: CGFloat = 156, zoom: Route? = nil) {
        self.init(title: title, subtitle: subtitle, width: width, zoom: zoom) {
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
                .zoomSource(.artist(artist), shape: RoundedRectangle(cornerRadius: width / 2))
            Text(artist.name)
                .font(.scaled(.subheadline).weight(.medium))
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

/// Any music item as the card a shelf shows for it. Songs play; everything else opens, out of
/// its cover, and a long press lifts it out with what can be done without opening it.
struct ItemCard: View {
    let item: MusicItem
    var width: CGFloat = 156
    /// In place of the usual line under the title (an artist's own albums show their year).
    var subtitle: String?
    var onPlay: (Song) -> Void

    var body: some View {
        switch item {
        case .song(let song):
            Button { onPlay(song) } label: {
                CoverCard(artwork: song.artwork, title: song.title, subtitle: subtitle ?? song.artistLine, width: width)
            }
            .buttonStyle(.plain)
            .contextMenu { SongMenuItems(song: song) } preview: { SongPreview(song: song) }
        case .album(let album):
            NavigationLink(value: Route.album(album)) {
                CoverCard(artwork: album.artwork, title: album.title, subtitle: subtitle ?? album.cardSubtitle, width: width, zoom: .album(album))
            }
            .buttonStyle(.plain)
            .contextMenu { CollectionMenuItems(item: item) } preview: { CollectionPreview(item: item, subtitle: subtitle) }
        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlist)) {
                CoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: subtitle ?? playlist.subtitle, width: width, zoom: .playlist(playlist))
            }
            .buttonStyle(.plain)
            .contextMenu { CollectionMenuItems(item: item) } preview: { CollectionPreview(item: item, subtitle: subtitle) }
        case .artist(let artist):
            NavigationLink(value: Route.artist(artist)) {
                ArtistCard(artist: artist, width: width * 0.8)
            }
            .buttonStyle(.plain)
            .contextMenu { CollectionMenuItems(item: item) } preview: { CollectionPreview(item: item, subtitle: subtitle) }
        }
    }
}

/// What a long press on an album's, playlist's or artist's card offers, as Music's do: play it
/// without opening it, keep it, pin it, share it.
struct CollectionMenuItems: View {
    let item: MusicItem
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        switch item {
        case .album(let album):
            Section {
                Button("Play", systemImage: "play") { app.playCollection(.album(album)) }
                Button("Shuffle", systemImage: "shuffle") { app.playCollection(.album(album), shuffled: true) }
            }
            Section {
                let saved = library.isSaved(album: album.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "minus.circle" : "plus") {
                    library.toggleSave(album)
                }
                PinMenuItem(pin: .album(album))
                ShareLink(item: URL(string: "https://music.youtube.com/browse/\(album.id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        case .playlist(let playlist):
            Section {
                Button("Play", systemImage: "play") { app.playCollection(.playlist(playlist)) }
                Button("Shuffle", systemImage: "shuffle") { app.playCollection(.playlist(playlist), shuffled: true) }
            }
            Section {
                let saved = library.isSaved(playlist: playlist.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "minus.circle" : "plus") {
                    library.toggleSave(playlist)
                }
                PinMenuItem(pin: .playlist(playlist))
                ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(playlist.id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        case .artist(let artist):
            Section {
                let saved = library.isSaved(artist: artist.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "minus.circle" : "plus") {
                    library.toggleSave(artist)
                }
                PinMenuItem(pin: .artist(artist))
                ShareLink(item: URL(string: "https://music.youtube.com/channel/\(artist.id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        case .song:
            EmptyView()
        }
    }
}

/// What a long press lifts out of a shelf for an album, playlist or artist: its cover large,
/// with its name, as `SongPreview` does for a song.
struct CollectionPreview: View {
    let item: MusicItem
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .artist = item {
                ArtworkView(artwork: item.artwork, size: 260, circle: true)
            } else {
                ArtworkView(artwork: item.artwork, size: 260, cornerRadius: 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.scaled(.headline)).lineLimit(2)
                if let line = subtitle ?? defaultSubtitle, !line.isEmpty {
                    Text(line).font(.scaled(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 292, alignment: .leading)
    }

    private var defaultSubtitle: String? {
        switch item {
        case .album(let album): album.cardSubtitle
        case .playlist(let playlist): playlist.subtitle
        case .artist(let artist): artist.subtitle ?? "Artist"
        case .song(let song): song.artistLine
        }
    }
}

import KodaCore
import SwiftUI

/// Search's Your Library scope on the iPhone: the listener's own songs, playlists, albums and
/// artists that match, updated as they type, as Music's Library scope is.
struct LibrarySearchResults: View {
    let query: String
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player

    var body: some View {
        let found = library.search(query, extra: downloads.store.completeSongs)
        List {
            if !found.songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(found.songs.prefix(50).enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song) { player.play(found.songs, startAt: index) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                    }
                }
            }
            if !found.userPlaylists.isEmpty {
                Section("Your Playlists") {
                    ForEach(found.userPlaylists) { playlist in
                        NavigationLink(value: Route.userPlaylist(playlist.id)) {
                            row(title: playlist.name, subtitle: songCount(playlist.songs.count)) {
                                PlaylistCover(playlist: playlist, size: 52, cornerRadius: 8)
                            }
                        }
                    }
                }
            }
            if !found.albums.isEmpty {
                Section("Albums") {
                    ForEach(found.albums) { album in
                        NavigationLink(value: Route.album(album)) {
                            row(title: album.title, subtitle: album.cardSubtitle) {
                                ArtworkView(artwork: album.artwork, size: 52, cornerRadius: 8)
                            }
                        }
                    }
                }
            }
            if !found.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(found.playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist)) {
                            row(title: playlist.title, subtitle: playlist.subtitle) {
                                ArtworkView(artwork: playlist.artwork, size: 52, cornerRadius: 8)
                            }
                        }
                    }
                }
            }
            if !found.artists.isEmpty {
                Section("Artists") {
                    ForEach(found.artists) { artist in
                        NavigationLink(value: Route.artist(artist)) {
                            row(title: artist.name, subtitle: nil) {
                                ArtworkView(artwork: artist.artwork, size: 52, circle: true)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if found.isEmpty {
                ContentUnavailableView {
                    Label("Not in Your Library", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing you've liked, saved, downloaded or played matches “\(query)”. Switch to YouTube Music to search everything.")
                }
            }
        }
    }

    private func row<Cover: View>(title: String, subtitle: String?, @ViewBuilder cover: () -> Cover) -> some View {
        HStack(spacing: 14) {
            cover()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The Mac's search results page in the Your Library scope.
struct MacLibrarySearchResults: View {
    let query: String
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player

    var body: some View {
        let found = library.search(query, extra: downloads.store.completeSongs)
        if found.isEmpty {
            ContentUnavailableView {
                Label("Not in Your Library", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing you've liked, saved, downloaded or played matches “\(query)”.")
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            if !found.songs.isEmpty {
                MacSectionTitle(title: "Songs")
                    .padding(.horizontal, MacMetrics.gutter)
                MacTrackList(songs: Array(found.songs.prefix(100))) { player.play(found.songs, startAt: $0) }
            }
            if !found.userPlaylists.isEmpty {
                MacShelf(title: "Your Playlists") {
                    ForEach(found.userPlaylists) { playlist in
                        NavigationLink(value: Route.userPlaylist(playlist.id)) {
                            MacCoverCard(title: playlist.name, subtitle: songCount(playlist.songs.count),
                                         onPlay: playlist.songs.isEmpty ? nil : { player.play(playlist.songs) }) {
                                PlaylistCover(playlist: playlist, size: MacMetrics.card, cornerRadius: 10)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !found.albums.isEmpty {
                MacShelf(title: "Albums") { ForEach(found.albums) { MacItemCard(item: .album($0)) } }
            }
            if !found.playlists.isEmpty {
                MacShelf(title: "Playlists") { ForEach(found.playlists) { MacItemCard(item: .playlist($0)) } }
            }
            if !found.artists.isEmpty {
                MacShelf(title: "Artists") { ForEach(found.artists) { MacArtistCard(artist: $0) } }
            }
        }
    }
}

private func songCount(_ count: Int) -> String {
    count == 1 ? "1 song" : "\(count) songs"
}

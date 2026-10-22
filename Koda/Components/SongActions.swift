import KodaCore
import SwiftUI

/// What can be done with a song, shared by its long-press menu and its ellipsis button.
struct SongMenuItems: View {
    let song: Song
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([song]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue([song]) }
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(from: song) }
        }
        Section {
            let liked = library.isLiked(song)
            Button(liked ? "Remove from Liked" : "Like", systemImage: liked ? "heart.slash" : "heart") { library.toggleLike(song) }
            AddToPlaylistMenu(songs: [song])
            DownloadMenuItem(song: song)
            if let album = song.album {
                Button("Go to Album", systemImage: "square.stack") {
                    model.open(.album(AlbumSummary(id: album.id, title: album.title, artistLine: song.artistLine, artists: song.artists, artwork: song.artwork)))
                }
            }
            GoToArtistItems(song: song) { model.open(.artist($0)) }
            ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(song.id)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Section {
            NotInterestedMenu(song: song)
        }
    }
}

/// "Suggest less" for a song or the artists on it: kept out of Home, mixes, radio and autoplay
/// from then on. The playing song, turned down, is skipped at once.
struct NotInterestedMenu: View {
    let song: Song
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        let artists = song.artists.filter { $0.id != nil }
        if library.notInterested.songs.contains(where: { $0.id == song.id }) {
            Button("Suggest This Song Again", systemImage: "hand.thumbsup") { library.unhide(song) }
        } else if artists.isEmpty {
            Button("Suggest Less of This Song", systemImage: "hand.thumbsdown") { hide { library.hide(song) } }
        } else {
            Menu("Suggest Less", systemImage: "hand.thumbsdown") {
                Button("This Song", systemImage: "music.note") { hide { library.hide(song) } }
                ForEach(artists, id: \.self) { artist in
                    if library.isHidden(artist: artist) {
                        Button("Suggest \(artist.name) Again", systemImage: "hand.thumbsup") { library.unhide(artist: artist) }
                    } else {
                        Button("Songs by \(artist.name)", systemImage: "music.mic") { hide { library.hide(artist: artist) } }
                    }
                }
            }
        }
    }

    private func hide(_ change: () -> Void) {
        change()
        if player.current?.id == song.id, library.isHidden(song) { player.next() }
    }
}

/// The ellipsis button at the end of a song row.
struct SongMenuButton: View {
    let song: Song

    var body: some View {
        if Platform.isMac {
            MacMoreMenu(size: 28, isGlass: false) { SongMenuItems(song: song) }
        } else {
            phoneMenu
        }
    }

    private var phoneMenu: some View {
        Menu {
            SongMenuItems(song: song)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More")
    }
}

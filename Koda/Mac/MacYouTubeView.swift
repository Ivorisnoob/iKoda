import KodaCore
import SwiftUI

/// The signed-in YouTube Music account on the Mac: who it is, the songs it
/// liked, and the playlists in its library.
///
/// What is shown is a mirror of the account, read at the last sync. The
/// listener's own library stays where it is, on the Library pages.
struct MacYouTubeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        MacPage {
            MacPageTitle(title: "YouTube Music", subtitle: app.account.name.isEmpty ? nil : app.account.name) {
                if app.account.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sync", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await app.account.sync(force: true) }
                    }
                    .buttonStyle(.glass)
                    .help("Read the account's library again")
                }
            }

            if !library.accountLiked.isEmpty {
                MacSectionTitle(title: "Liked on YouTube", subtitle: "\(library.accountLiked.count) songs")
                MacTrackList(songs: Array(library.accountLiked.prefix(100)), play: { index in
                    player.play(library.accountLiked, startAt: index)
                })
            }

            if !library.accountPlaylists.isEmpty {
                MacSectionTitle(title: "Your YouTube Music Playlists", subtitle: "\(library.accountPlaylists.count) playlists")
                MacGrid(items: library.accountPlaylists) { playlist, side in
                    NavigationLink(value: Route.playlist(playlist)) {
                        MacCoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.subtitle,
                                     width: side)
                    }
                    .buttonStyle(.plain)
                }
            }

            if library.accountLiked.isEmpty && library.accountPlaylists.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Synced Yet", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("Koda reads the songs you liked and the playlists in your YouTube Music library. Sync to fetch them.")
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .navigationTitle("YouTube Music")
    }
}

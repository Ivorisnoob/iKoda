import KodaCore
import SwiftUI

/// Every page a navigation stack can push.
enum Route: Hashable {
    case album(AlbumSummary)
    case artist(ArtistSummary)
    case playlist(PlaylistSummary)
    case mood(Mood)
    /// A plain list of songs the app already holds: liked, recently played.
    case songs(title: String, source: SongSource)
    case shelf(Shelf)
    /// A playlist made on this phone.
    case userPlaylist(UUID)
    /// Listening statistics in full.
    case stats
    /// Every play, by day.
    case history
    /// Songs the app put together, such as Your Mix.
    case songList(title: String, subtitle: String?, songs: [Song])
    /// The player, as a page of its own on the Mac, zooming out of the player bar's cover.
    case nowPlaying

    enum SongSource: Hashable {
        case liked, recent, downloaded
        /// Every song held whole on the device: downloads and songs kept from listening.
        case offline
    }

    init?(_ item: MusicItem) {
        switch item {
        case .album(let a): self = .album(a)
        case .artist(let a): self = .artist(a)
        case .playlist(let p): self = .playlist(p)
        case .song: return nil
        }
    }
}

extension View {
    /// The destinations every tab's stack can reach.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let album): AlbumView(summary: album)
            case .artist(let artist): ArtistView(summary: artist)
            case .playlist(let playlist): PlaylistView(summary: playlist)
            case .mood(let mood): MoodView(mood: mood)
            case .songs(let title, let source): SavedSongsView(title: title, source: source)
            case .shelf(let shelf): ShelfGridView(shelf: shelf)
            case .userPlaylist(let id): UserPlaylistView(id: id)
            case .stats: StatsView()
            case .history: HistoryView()
            case .songList(let title, let subtitle, let songs): SongListView(title: title, subtitle: subtitle, songs: songs)
            case .nowPlaying: NowPlayingPage()
            }
        }
    }
}

/// Now Playing pushed onto a page's stack, with the system's zoom out of the player bar's cover
/// (`matchedTransitionSource` "player" in the namespace the window provides).
struct NowPlayingPage: View {
    @Environment(\.nowPlayingZoom) private var zoom

    var body: some View {
        if let zoom {
            NowPlayingView()
                .navigationTitle("Now Playing")
                .navigationTransition(.zoom(sourceID: "player", in: zoom))
        } else {
            NowPlayingView()
                .navigationTitle("Now Playing")
        }
    }
}

extension EnvironmentValues {
    /// The namespace the player bar's cover is marked in, for Now Playing to zoom out of.
    @Entry var nowPlayingZoom: Namespace.ID? = nil
}

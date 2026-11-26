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
    /// A YouTube video's watch page.
    case video(Video)
    /// A YouTube channel's page.
    case channel(id: String, name: String)
    /// The videos watched, most recent first.
    case watched
    /// A playlist of videos: Watch Later (`WL`), Liked Videos (`LL`).
    case videoPlaylist(id: String, title: String)
    /// A topic's shelves: Music, Live, News…
    case explore(ExploreTopic)
    /// The channels the account subscribes to.
    case subscribedChannels
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
        modifier(RouteDestinations())
    }

    /// Marks the cover a page opens from, so the page zooms out of it (iPhone): the system's
    /// zoom transition, as Photos and the App Store open things.
    func zoomSource(_ route: Route?, shape: RoundedRectangle = RoundedRectangle(cornerRadius: 10, style: .continuous)) -> some View {
        modifier(ZoomSource(route: route, shape: shape))
    }
}

private struct RouteDestinations: ViewModifier {
    /// One per stack: a cover marked in it is found by the page pushed onto the same stack.
    @Namespace private var zoom

    func body(content: Content) -> some View {
        content
            .environment(\.routeZoom, zoom)
            .navigationDestination(for: Route.self) { route in
                destination(route)
                    .zoomTransition(route.zooms ? route : nil, in: zoom)
                    // Set again here: a pushed page doesn't always take the stack's root environment.
                    .environment(\.routeZoom, zoom)
            }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
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
        case .video(let video): VideoWatchView(video: video)
        case .channel(let id, let name): ChannelView(channelId: id, name: name)
        case .watched: VideoLibraryView()
        case .videoPlaylist(let id, let title): VideoPlaylistView(playlistId: id, title: title)
        case .explore(let topic): ExploreView(topic: topic)
        case .subscribedChannels: SubscribedChannelsView()
        case .songList(let title, let subtitle, let songs): SongListView(title: title, subtitle: subtitle, songs: songs)
        case .nowPlaying: NowPlayingPage()
        }
    }
}

extension Route {
    /// Pages that open out of a cover; the rest push as usual.
    var zooms: Bool {
        switch self {
        case .album, .artist, .playlist, .userPlaylist: true
        default: false
        }
    }
}

private struct ZoomSource: ViewModifier {
    let route: Route?
    /// The cover's own corners, which the page keeps as it grows out of them (a circle is a
    /// square rounded by half its side).
    let shape: RoundedRectangle
    @Environment(\.routeZoom) private var zoom

    func body(content: Content) -> some View {
        #if os(iOS)
        if let route, route.zooms, let zoom {
            content.matchedTransitionSource(id: route, in: zoom) { $0.clipShape(shape) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private extension View {
    @ViewBuilder
    func zoomTransition(_ route: Route?, in zoom: Namespace.ID) -> some View {
        #if os(iOS)
        if let route {
            navigationTransition(.zoom(sourceID: route, in: zoom))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// The stack's namespace for zoom transitions; nil outside a stack.
    @Entry var routeZoom: Namespace.ID? = nil
}

/// Now Playing pushed onto a page's stack, with the system's zoom out of the player bar's cover
/// (`matchedTransitionSource` "player" in the namespace the window provides).
struct NowPlayingPage: View {
    @Environment(\.nowPlayingZoom) private var zoom

    var body: some View {
        #if os(iOS)
        if let zoom {
            NowPlayingView()
                .navigationTitle("Now Playing")
                .navigationTransition(.zoom(sourceID: "player", in: zoom))
        } else {
            NowPlayingView()
                .navigationTitle("Now Playing")
        }
        #else
        // AppKit's SwiftUI has no zoom transition; the page pushes as any other does.
        NowPlayingView()
            .navigationTitle("Now Playing")
        #endif
    }
}

extension EnvironmentValues {
    /// The namespace the player bar's cover is marked in, for Now Playing to zoom out of.
    @Entry var nowPlayingZoom: Namespace.ID? = nil
}

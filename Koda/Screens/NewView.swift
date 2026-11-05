import KodaCore
import SwiftUI

/// What's out now, as Music's New tab: YouTube Music's new albums and singles, what's trending,
/// the charts and new music videos. Home is the listener's own; this is everyone's.
struct NewView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var state: LoadState<Page> = .loading

    struct Page {
        var shelves: [Shelf]
        var charts: [PlaylistSummary]

        /// The page's shape, drawn redacted while it loads.
        static let placeholder = Page(
            shelves: [
                Shelf(title: "New albums & singles", items: (0..<6).map { .album(AlbumSummary.placeholder($0)) }),
                Shelf(title: "Trending", items: Song.placeholders(8).map(MusicItem.song)),
            ],
            charts: (0..<6).map { PlaylistSummary(id: "placeholder-\($0)", title: "Top 100 Chart") }
        )
    }

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    private var phoneBody: some View {
        ScrollView {
            AsyncContent(state: state, retry: load, placeholder: .placeholder) { page in
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(Array(page.shelves.enumerated()), id: \.element.id) { index, shelf in
                        phoneShelf(shelf)
                        // The charts follow the first shelf, the new releases.
                        if index == 0 { phoneCharts(page.charts) }
                    }
                    if page.shelves.isEmpty { phoneCharts(page.charts) }
                }
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("New")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
        .refreshable { await load(fresh: true) }
        .task { if state.value == nil { await load() } }
    }

    /// Shelves of songs page sideways in columns, as Quick picks do; the rest are cards.
    @ViewBuilder
    private func phoneShelf(_ shelf: Shelf) -> some View {
        let songs = Self.songs(shelf)
        if songs.count == shelf.items.count {
            SongColumnsShelf(title: shelf.title, strapline: shelf.strapline, songs: songs) { player.play(songs, startAt: $0) }
        } else {
            ItemShelf(shelf: shelf) { player.startRadio(from: $0) }
        }
    }

    @ViewBuilder
    private func phoneCharts(_ charts: [PlaylistSummary]) -> some View {
        if !charts.isEmpty {
            ShelfView(title: "Charts", strapline: "Global and near you") {
                ForEach(charts) { chart in
                    NavigationLink(value: Route.playlist(chart)) {
                        CoverCard(artwork: chart.artwork, title: chart.title, subtitle: chart.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var macBody: some View {
        MacPage {
            MacPageTitle(title: "New", subtitle: "Out now on YouTube Music")
            AsyncContent(state: state, retry: load, placeholder: .placeholder) { page in
                ForEach(Array(page.shelves.enumerated()), id: \.element.id) { index, shelf in
                    MacItemShelf(shelf: shelf)
                    if index == 0 { macCharts(page.charts) }
                }
                if page.shelves.isEmpty { macCharts(page.charts) }
            }
        }
        .navigationTitle("New")
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private func macCharts(_ charts: [PlaylistSummary]) -> some View {
        if !charts.isEmpty {
            MacShelf(title: "Charts", subtitle: "Global and near you") {
                ForEach(charts) { MacItemCard(item: .playlist($0)) }
            }
        }
    }

    private static func songs(_ shelf: Shelf) -> [Song] {
        shelf.items.compactMap { item in
            if case .song(let song) = item { return song }
            return nil
        }
    }

    private func load() async { await load(fresh: false) }

    private func load(fresh: Bool) async {
        if fresh { await app.music.clearPageCache() }
        if state.value == nil { state = .loading }
        async let charts = try? app.music.chartPlaylists()
        do {
            let explore = try await app.music.explore()
            let hidden = app.library.notInterested
            // Songs the listener asked not to be offered stay out here too.
            let shelves = explore.shelves.compactMap { shelf -> Shelf? in
                var shelf = shelf
                shelf.items = shelf.items.filter { item in
                    if case .song(let song) = item { return !hidden.hides(song) }
                    return true
                }
                return shelf.items.isEmpty ? nil : shelf
            }
            state = .loaded(Page(shelves: shelves, charts: await charts ?? []))
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }
}

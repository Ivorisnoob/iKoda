import KodaCore
import SwiftUI

/// How saved albums, playlists and artists are ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, artist

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .title: "Title"
        case .artist: "Artist"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .title: "textformat"
        case .artist: "music.mic"
        }
    }
}

/// What the listener saved on this phone.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @AppStorage("koda.library.sort") private var sort: LibrarySort = .recent
    @State private var showsProfile = false

    private var isEmpty: Bool {
        library.liked.isEmpty && library.albums.isEmpty && library.playlists.isEmpty && library.artists.isEmpty
            && library.recent.isEmpty && library.userPlaylists.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 0) {
                    LibraryLink(title: "Liked Songs", systemImage: "heart.fill", tint: .pink, count: library.liked.count,
                                route: .songs(title: "Liked Songs", source: .liked))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: "Downloads", systemImage: "arrow.down.circle.fill", tint: .blue, count: downloads.songs.count,
                                route: .songs(title: "Downloads", source: .downloaded))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: "Ready Offline", systemImage: "airplane", tint: .green, count: 0,
                                route: .songs(title: "Ready Offline", source: .offline))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: "Recently Played", systemImage: "clock.fill", tint: .orange, count: library.recent.count,
                                route: .songs(title: "Recently Played", source: .recent))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: "Listening Stats", systemImage: "chart.bar.fill", tint: .teal, count: 0, route: .stats)
                }
                .padding(.horizontal, 20)

                yourPlaylists

                if !library.playlists.isEmpty {
                    grid("Saved Playlists", items: sorted(library.playlists).map(MusicItem.playlist))
                }
                if !library.albums.isEmpty {
                    grid("Albums", items: sorted(library.albums).map(MusicItem.album))
                }
                if !library.artists.isEmpty {
                    ShelfView(title: "Artists") {
                        ForEach(sortedArtists) { artist in
                            NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist, width: 100) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if isEmpty {
                    ContentUnavailableView("Your Library Is Empty", systemImage: "square.stack",
                                           description: Text("Like songs, make playlists, and add albums, playlists and artists with the + button on their pages."))
                        .padding(.top, 20)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { showsProfile = true }
            }
        }
        .sheet(isPresented: $showsProfile) { ProfileView().appEnvironment(app) }
    }

    // MARK: Your playlists

    private var yourPlaylists: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your Playlists")
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NewPlaylistTile()
                    ForEach(sortedUserPlaylists) { playlist in
                        NavigationLink(value: Route.userPlaylist(playlist.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                PlaylistMosaic(songs: playlist.songs, size: 140, cornerRadius: 10)
                                Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(playlist.songs.count == 1 ? "1 song" : "\(playlist.songs.count) songs")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    // MARK: Sorting

    private var sortedUserPlaylists: [UserPlaylist] {
        switch sort {
        case .recent: library.userPlaylists
        case .title, .artist: library.userPlaylists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        switch sort {
        case .recent: albums
        case .title: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: albums.sorted { localizedLess(($0.artistLine, $0.title), ($1.artistLine, $1.title)) }
        }
    }

    private func sorted(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        switch sort {
        case .recent: playlists
        case .title: playlists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: playlists.sorted { localizedLess(($0.subtitle ?? "", $0.title), ($1.subtitle ?? "", $1.title)) }
        }
    }

    private var sortedArtists: [ArtistSummary] {
        sort == .recent ? library.artists : library.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func grid(_ title: String, items: [MusicItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(items) { item in
                    if let route = Route(item) {
                        NavigationLink(value: route) {
                            GeometryReader { geometry in
                                CoverCard(artwork: item.artwork, title: item.title, subtitle: subtitle(item), width: geometry.size.width)
                            }
                            .aspectRatio(0.78, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func subtitle(_ item: MusicItem) -> String? {
        switch item {
        case .album(let a): a.cardSubtitle
        case .playlist(let p): p.subtitle
        default: nil
        }
    }
}

/// Orders by the first string, then the second, as Finder would.
private func localizedLess(_ a: (String, String), _ b: (String, String)) -> Bool {
    switch a.0.localizedStandardCompare(b.0) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.1.localizedStandardCompare(b.1) == .orderedAscending
    }
}

/// The first tile among the listener's playlists: makes a new one.
private struct NewPlaylistTile: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var naming = false
    @State private var draftName = ""
    @State private var created = 0

    var body: some View {
        Button {
            draftName = ""
            naming = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 140, height: 140)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                Text("New Playlist").font(.subheadline.weight(.medium))
                Text(" ").font(.footnote)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: created)
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                created += 1
                app.open(.userPlaylist(library.createPlaylist(named: draftName).id))
            }
        } message: {
            Text("Add songs to it from any song's menu.")
        }
    }
}

private struct LibraryLink: View {
    let title: String
    let systemImage: String
    let tint: Color
    let count: Int
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.gradient, in: .rect(cornerRadius: 9, style: .continuous))
                Text(title).font(.body)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

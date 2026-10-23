import KodaCore
import SwiftUI

struct AlbumView: View {
    let summary: AlbumSummary

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var state: LoadState<AlbumPage> = .loading
    @State private var palette = PaletteModel()

    private var album: AlbumSummary { state.value?.album ?? summary }

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    /// The Mac's album: the cover beside its details, buttons at their own size, and the
    /// tracks as a list with columns, numbered as on the record.
    private var macBody: some View {
        MacPage(spacing: 28) {
            MacCollectionHeader(
                kind: [album.kind?.rawValue ?? "Album", album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                title: album.title,
                byline: album.artistLine,
                bylineArtists: album.artists,
                openArtist: { app.open(.artist($0)) },
                detail: state.value?.detailLine,
                description: state.value?.description,
                accent: palette.palette.accent,
                canPlay: !(state.value?.songs.isEmpty ?? true),
                play: { play(shuffled: false) },
                shuffle: { play(shuffled: true) }
            ) {
                ArtworkView(artwork: album.artwork ?? summary.artwork, size: 232, cornerRadius: 12)
            } actions: {
                macActions
            }
            AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                VStack(alignment: .leading, spacing: 36) {
                    MacTrackList(songs: page.songs, numbered: true,
                                 showsArtist: page.songs.contains { $0.artistLine != page.album.artistLine },
                                 showsAlbum: false) { player.play(page.songs, startAt: $0) }
                    if !page.otherVersions.isEmpty {
                        MacShelf(title: "Other versions") {
                            ForEach(page.otherVersions) { MacItemCard(item: .album($0)) }
                        }
                    }
                }
            }
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationTitle(album.title)
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private var macActions: some View {
        let saved = library.isSaved(album: summary.id)
        Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
            library.toggleSave(album)
        }
        .buttonStyle(MacIconButtonStyle())
        .help(saved ? "Remove from Library" : "Add to Library")
        if let songs = state.value?.songs, !songs.isEmpty {
            DownloadButton(songs: songs)
                .buttonStyle(MacIconButtonStyle())
            MacMoreMenu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(songs) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(songs) }
                AddToPlaylistMenu(songs: songs)
                ShareLink(item: URL(string: "https://music.youtube.com/browse/\(summary.id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                CollectionHeader(
                    artwork: album.artwork ?? summary.artwork,
                    title: album.title,
                    byline: album.artistLine,
                    bylineArtists: album.artists,
                    openArtist: { app.open(.artist($0)) },
                    detail: [album.kind?.rawValue, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                    description: state.value?.description,
                    accent: palette.palette.accent,
                    play: { play(shuffled: false) },
                    shuffle: { play(shuffled: true) })

                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    VStack(alignment: .leading, spacing: 24) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(page.songs.enumerated()), id: \.offset) { index, song in
                                SongRow(song: song, number: index + 1, showsArtwork: false,
                                        subtitle: song.artistLine == page.album.artistLine ? durationText(song) : song.artistLine) {
                                    player.play(page.songs, startAt: index)
                                }
                                if index < page.songs.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        if let detail = page.detailLine {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                        }
                        if !page.otherVersions.isEmpty {
                            ShelfView(title: "Other versions") {
                                ForEach(page.otherVersions) { other in
                                    NavigationLink(value: Route.album(other)) {
                                        CoverCard(artwork: other.artwork, title: other.title, subtitle: other.cardSubtitle)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationBarTitleDisplayMode(.inline)
        .revealsTitle(album.title, after: 320)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(album: summary.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                    library.toggleSave(album)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
            if let songs = state.value?.songs, !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    DownloadButton(songs: songs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    if let songs = state.value?.songs, !songs.isEmpty {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(songs) }
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(songs) }
                        AddToPlaylistMenu(songs: songs)
                    }
                    ShareLink(item: URL(string: "https://music.youtube.com/browse/\(summary.id)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    private func durationText(_ song: Song) -> String {
        guard let d = song.duration else { return song.artistLine }
        return Duration.seconds(d).formatted(.time(pattern: .minuteSecond))
    }

    private func play(shuffled: Bool) {
        guard let songs = state.value?.songs, !songs.isEmpty else { return }
        player.play(songs, startAt: shuffled ? Int.random(in: 0..<songs.count) : 0, shuffled: shuffled)
    }

    private func load() async {
        state = .loading
        do {
            let page = try await app.music.album(summary.id)
            state = .loaded(page)
            if summary.artwork == nil { await palette.load(page.album.artwork) }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

import KodaCore
import SwiftUI

struct PlaylistView: View {
    let summary: PlaylistSummary

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var state: LoadState<PlaylistPage> = .loading
    @State private var songs: [Song] = []
    @State private var continuation: String?
    @State private var loadingMore = false
    @State private var palette = PaletteModel()

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    /// The Mac's playlist: the cover beside its details, then songs with their artist and
    /// album columns, loading the next page as the end comes into view.
    private var macBody: some View {
        let title = state.value?.playlist.title ?? summary.title
        return MacPage(spacing: 28) {
            MacCollectionHeader(
                kind: "Playlist",
                title: title,
                byline: state.value?.author ?? summary.subtitle,
                detail: state.value?.detailLine,
                description: state.value?.description,
                accent: palette.palette.accent,
                canPlay: !songs.isEmpty,
                play: { play(shuffled: false) },
                shuffle: { play(shuffled: true) }
            ) {
                ArtworkView(artwork: state.value?.playlist.artwork ?? summary.artwork, size: 232, cornerRadius: 12)
            } actions: {
                macActions
            }
            AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                let rows = state.value == nil ? page.songs : songs
                VStack(spacing: 12) {
                    MacTrackList(songs: rows, play: { player.play(songs, startAt: $0) },
                                 onRowAppear: { index in if index >= songs.count - 10 { Task { await loadMore() } } })
                    if loadingMore { ProgressView().controlSize(.small) }
                }
            }
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationTitle(title)
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private var macActions: some View {
        let saved = library.isSaved(playlist: summary.id)
        Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
            library.toggleSave(state.value?.playlist ?? summary)
        }
        .buttonStyle(MacIconButtonStyle())
        .help(saved ? "Remove from Library" : "Add to Library")
        if !songs.isEmpty {
            DownloadButton(songs: songs, allSongs: allSongs)
                .buttonStyle(MacIconButtonStyle())
        }
        MacMoreMenu {
            if !songs.isEmpty {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(songs) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(songs) }
                AddToPlaylistMenu(songs: songs)
            }
            ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(summary.id)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                CollectionHeader(
                    artwork: state.value?.playlist.artwork ?? summary.artwork,
                    title: state.value?.playlist.title ?? summary.title,
                    byline: state.value?.author ?? summary.subtitle,
                    detail: state.value?.detailLine,
                    description: state.value?.description,
                    accent: palette.palette.accent,
                    play: { play(shuffled: false) },
                    shuffle: { play(shuffled: true) })

                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    // `songs` grows past the first page as the list scrolls; while loading it is empty.
                    let rows = state.value == nil ? page.songs : songs
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, song in
                            SongRow(song: song) { player.play(songs, startAt: index) }
                                .onAppear { if index >= songs.count - 10 { Task { await loadMore() } } }
                        }
                        if loadingMore {
                            ProgressView().padding()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationBarTitleDisplayMode(.inline)
        .revealsTitle(state.value?.playlist.title ?? summary.title, after: 320)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(playlist: summary.id)
                Button(saved ? "Remove from Library" : "Add to Library", systemImage: saved ? "checkmark" : "plus") {
                    library.toggleSave(state.value?.playlist ?? summary)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    DownloadButton(songs: songs, allSongs: allSongs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    if !songs.isEmpty {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(songs) }
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(songs) }
                        AddToPlaylistMenu(songs: songs)
                    }
                    ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(summary.id)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    private func play(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: shuffled ? Int.random(in: 0..<songs.count) : 0, shuffled: shuffled)
    }

    private func load() async {
        state = .loading
        do {
            let page = try await app.music.playlist(summary.id)
            songs = page.songs
            continuation = page.continuation
            state = .loaded(page)
            if summary.artwork == nil { await palette.load(page.playlist.artwork) }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    /// Every song, loading the pages not scrolled to yet, for downloading the whole playlist.
    private func allSongs() async -> [Song] {
        while continuation != nil {
            if loadingMore {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let before = songs.count
            await loadMore()
            // A page that failed to load: download what there is.
            if songs.count == before { break }
        }
        return songs
    }

    private func loadMore() async {
        guard !loadingMore, let token = continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await app.music.playlistMore(token) else { return }
        songs += page.songs
        continuation = page.continuation
    }
}

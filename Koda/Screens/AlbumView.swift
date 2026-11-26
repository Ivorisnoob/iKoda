import KodaCore
import SwiftUI

struct AlbumView: View {
    let summary: AlbumSummary

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var state: LoadState<AlbumPage> = .loading
    @State private var palette = PaletteModel()
    @State private var opening = Opening()
    /// The animated covers found on this visit, playing in the square cover.
    @State private var squareCovers: MotionArtwork.Covers?
    /// The artist's other records, for the foot of the page.
    @State private var moreByArtist: [AlbumSummary] = []

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
            ) { side in
                ArtworkView(artwork: album.artwork ?? summary.artwork, size: side, cornerRadius: 12)
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
                PinMenuItem(pin: .album(summary))
                ShareLink(item: URL(string: "https://music.youtube.com/browse/\(summary.id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var phoneBody: some View {
        let tall = tallCovers
        return ScrollView {
            VStack(spacing: 24) {
                if let tall {
                    // The tall loop across the top of the page, as Music shows it, the header
                    // over its foot where it has melted into the page.
                    VStack(spacing: 0) {
                        AlbumMotionArt(covers: tall)
                        header(showsArtwork: false)
                            .padding(.top, -132)
                    }
                } else {
                    header(showsArtwork: true)
                }

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

                        // The record's own details at its foot, as on the back of the sleeve.
                        let foot = [album.year.map { "Released \($0)" }, page.detailLine].compactMap { $0 }
                        if !foot.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(foot, id: \.self) { Text($0) }
                            }
                            .font(.scaled(.footnote))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                        }
                        if !moreByArtist.isEmpty, let artist = album.artists.first {
                            ShelfView(title: "More by \(artist.name)") {
                                ForEach(moreByArtist) { other in
                                    ItemCard(item: .album(other),
                                             subtitle: [other.kind?.rawValue, other.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")) { _ in }
                                }
                            }
                        }
                        if !page.otherVersions.isEmpty {
                            ShelfView(title: "Other versions") {
                                ForEach(page.otherVersions) { other in
                                    ItemCard(item: .album(other)) { _ in }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background { if tall == nil { ArtworkGlow(palette: palette.palette) } }
        .ignoresSafeArea(.container, edges: tall == nil ? [] : .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .revealsTitle(album.title, after: tall == nil ? 320 : 520)
        #if os(iOS)
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
                    PinMenuItem(pin: .album(summary))
                    ShareLink(item: URL(string: "https://music.youtube.com/browse/\(summary.id)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        #endif
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
    }

    private func header(showsArtwork: Bool) -> some View {
        CollectionHeader(
            artwork: album.artwork ?? summary.artwork,
            title: album.title,
            byline: album.artistLine,
            bylineArtists: album.artists,
            openArtist: { app.open(.artist($0)) },
            detail: [album.kind?.rawValue, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
            description: state.value?.description,
            accent: palette.palette.accent,
            motion: showsArtwork ? squareCovers : nil,
            showsArtwork: showsArtwork,
            play: { play(shuffled: false) },
            shuffle: { play(shuffled: true) })
    }

    /// The album's tall loop when it was already known as the page opened, decided once: the
    /// page is laid out around it from the first frame or not at all, so nothing jumps when a
    /// loop turns up on a first visit (that one plays in the square cover instead).
    private var tallCovers: MotionArtwork.Covers? {
        if let decided = opening.covers { return decided }
        let known = app.settings.animatedArt == .off ? nil : app.albumMotion[summary.id].flatMap { $0.masters[.tall] == nil ? nil : $0 }
        opening.covers = .some(known)
        return known
    }

    /// Holds the first answer; a class, so reading it in the body doesn't redraw the page.
    private final class Opening {
        var covers: MotionArtwork.Covers??
    }

    /// The album's animated covers, asked for with its first song once the page has loaded,
    /// remembered for the next time it opens; then the "More by" shelf from the artist's page.
    private func lookAround(_ page: AlbumPage) async {
        if app.settings.animatedArt != .off, var song = page.songs.first(where: { !$0.isVideo }) {
            if song.album == nil { song.album = AlbumRef(id: summary.id, title: page.album.title) }
            if let covers = await app.motionArtwork.covers(for: song, allowsCellular: app.settings.animatedArt.allowsCellular) {
                app.albumMotion[summary.id] = covers
                if tallCovers == nil { withAnimation(.smooth) { squareCovers = covers } }
            }
        }
        guard let artistID = page.album.artists.first?.id ?? summary.artists.first?.id,
              let artistPage = try? await app.music.artist(artistID) else { return }
        let others = (artistPage.albums + artistPage.singles).filter { $0.id != summary.id && !MotionArtworkCatalog.sameRelease($0.title, page.album.title) }
        withAnimation(.smooth) { moreByArtist = Array(others.prefix(12)) }
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
            if !Platform.isMac { await lookAround(page) }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// An album's tall loop across the top of its page, under the status bar, its still frame
/// first, melting into the page towards its foot so the title can sit on it.
private struct AlbumMotionArt: View {
    let covers: MotionArtwork.Covers
    @State private var onScreen = true

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = width / MotionArtwork.Shape.tall.aspect
            ZStack {
                if let still = covers.preview(.tall, pixels: 1080) {
                    ArtworkView(artwork: Artwork(url: still), size: width, cornerRadius: 0, fillsFrame: true)
                }
                MotionLoop(covers: covers, shape: .tall, isPlaying: onScreen)
            }
            .frame(width: width, height: height)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6),
                                         .init(color: .clear, location: 0.97)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .aspectRatio(MotionArtwork.Shape.tall.aspect, contentMode: .fit)
        .onScrollVisibilityChange(threshold: 0.05) { onScreen = $0 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

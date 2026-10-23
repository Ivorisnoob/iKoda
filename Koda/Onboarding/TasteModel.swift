import KodaCore
import SwiftUI

/// Taste setup: pick artists (each pick brings in more like them), pick genres, then keep or
/// skip a short deck of songs built from both. Koda for Android's taste setup.
///
/// The grid starts from the listener, not a chart: someone with a library opens it with their
/// own artists picked and the artists their listeners also like after them; charts fill in behind,
/// and are the whole grid only for a new install, the local chart taken in turn with the US one
/// (one country's chart alone is a poor guess at a stranger).
///
/// Every pick and answer is saved as it is made, so leaving half-way keeps what was chosen.
@MainActor
@Observable
final class TasteModel {
    nonisolated struct Card: Identifiable, Equatable, Sendable {
        let song: Song
        /// Why it's in the deck, shown on the card.
        let reason: String
        var id: String { song.id }
    }

    enum Answer {
        /// Not for me: kept out of suggestions from now on.
        case skip
        case keep
        /// Kept and liked.
        case love
    }

    private(set) var grid: [ArtistSummary] = []
    private(set) var picked: [ArtistSummary]
    private(set) var isLoadingArtists = true
    private(set) var artistsFailed = false
    var query = ""
    private(set) var results: [ArtistSummary] = []
    private(set) var isSearching = false
    private(set) var genres: Set<String>
    private(set) var deck: [Card] = []
    private(set) var deckIndex = 0
    private(set) var isLoadingDeck = false
    private(set) var kept = 0
    private(set) var loved = 0

    private let music: YouTubeMusic
    private let library: Library
    @ObservationIgnored private var started = false
    @ObservationIgnored private var similarShown = Set<String>()

    static let deckSize = 18

    init(music: YouTubeMusic, library: Library) {
        self.music = music
        self.library = library
        picked = library.taste.artists
        genres = Set(library.taste.genres)
    }

    var current: Card? { deck.indices.contains(deckIndex) ? deck[deckIndex] : nil }
    func isPicked(_ artist: ArtistSummary) -> Bool { picked.contains { $0.id == artist.id } }

    // MARK: Artists

    func start() async {
        guard !started else { return }
        started = true
        isLoadingArtists = true
        artistsFailed = false
        async let local = try? music.chartArtists()
        async let broad = try? music.chartArtists(country: "US")
        if picked.isEmpty { picked = await artistsFromLibrary() }
        // The picks show at once; who their listeners like follows, then the charts.
        grid = picked
        let similar = await similarToPicks()
        let charts = Self.interleave([await local ?? [], await broad ?? []])
        grid = Self.unique(picked + similar + charts)
        isLoadingArtists = false
        artistsFailed = grid.isEmpty
        if !picked.isEmpty { library.setTasteArtists(picked) }
    }

    func retry() async {
        started = false
        await start()
    }

    func toggle(_ artist: ArtistSummary) {
        if isPicked(artist) {
            picked.removeAll { $0.id == artist.id }
        } else {
            picked.append(artist)
            if !grid.contains(where: { $0.id == artist.id }) { grid.insert(artist, at: 0) }
            Task { await showMoreLike(artist) }
        }
        library.setTasteArtists(picked)
    }

    /// A few of the artist's "fans also like", right after them in the grid.
    private func showMoreLike(_ artist: ArtistSummary) async {
        guard artist.id.hasPrefix("UC"), similarShown.insert(artist.id).inserted,
              let similar = try? await music.artist(artist.id).similar else { return }
        let shown = Set(grid.map(\.id))
        let fresh = similar.filter { !shown.contains($0.id) }.prefix(4)
        // Unpicked again before the answer came: nothing to sit beside.
        guard isPicked(artist), !fresh.isEmpty, let at = grid.firstIndex(where: { $0.id == artist.id }) else { return }
        withAnimation(.snappy) { grid.insert(contentsOf: fresh, at: at + 1) }
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let found = try? await music.search(text, filter: .artists) else { return }
        results = found.artists
    }

    /// The library's artists to start from: saved ones, then the most played and most liked,
    /// each with its picture where the library doesn't have one.
    private func artistsFromLibrary() async -> [ArtistSummary] {
        var refs: [ArtistSummary] = library.artists
        let taste = Taste(library: library, maxSeeds: 0)
        var byName: [String: ArtistRef] = [:]
        for song in library.songStats.values.map(\.song) + library.liked {
            if let ref = song.artists.first, ref.id != nil, byName[ref.name] == nil { byName[ref.name] = ref }
        }
        refs += taste.artists.compactMap { byName[$0] }.compactMap { ref in ref.id.map { ArtistSummary(id: $0, name: ref.name) } }
        let chosen = Array(Self.unique(refs).prefix(8))
        return await withTaskGroup(of: (Int, ArtistSummary).self) { group in
            for (index, artist) in chosen.enumerated() {
                group.addTask { [music] in
                    guard artist.artwork == nil, let page = try? await music.artist(artist.id) else { return (index, artist) }
                    return (index, ArtistSummary(id: artist.id, name: artist.name, subtitle: artist.subtitle, artwork: page.artist.artwork))
                }
            }
            var filled = chosen
            for await (index, artist) in group { filled[index] = artist }
            return filled
        }
    }

    private func similarToPicks() async -> [ArtistSummary] {
        let seeds = picked.filter { $0.id.hasPrefix("UC") }.prefix(4)
        let lists = await withTaskGroup(of: (Int, [ArtistSummary]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { [music] in (index, Array(((try? await music.artist(seed.id).similar) ?? []).prefix(4))) }
            }
            var byIndex: [Int: [ArtistSummary]] = [:]
            for await (index, list) in group { byIndex[index] = list }
            return seeds.indices.map { byIndex[$0] ?? [] }
        }
        similarShown.formUnion(seeds.map(\.id))
        return Self.interleave(lists)
    }

    // MARK: Genres

    func toggle(genre: String) {
        if genres.contains(genre) { genres.remove(genre) } else { genres.insert(genre) }
        library.setTasteGenres(TasteProfile.genres.filter(genres.contains))
    }

    // MARK: Deck

    /// A minute or two of songs: two each from up to five picked artists, three each from up to
    /// three genres, and a few from one pick's radio that nobody picked, taken in turn.
    func buildDeck() async {
        guard deck.isEmpty, !isLoadingDeck else { return }
        isLoadingDeck = true
        defer { isLoadingDeck = false }
        let artists = Array(picked.filter { $0.id.hasPrefix("UC") }.shuffled().prefix(5))
        let genreNames = Array(genres.shuffled().prefix(3))
        async let fromArtists = withTaskGroup(of: [Card].self) { group in
            for artist in artists {
                group.addTask { [music] in
                    let songs = ((try? await music.artist(artist.id).topSongs) ?? []).prefix(2)
                    return songs.map { Card(song: $0, reason: "Because you like \(artist.name)") }
                }
            }
            var all: [[Card]] = []
            for await cards in group { all.append(cards) }
            return all
        }
        async let fromGenres = withTaskGroup(of: [Card].self) { group in
            for genre in genreNames {
                group.addTask { [music] in
                    let songs = ((try? await music.search("\(genre) songs", filter: .songs).songs) ?? []).prefix(3)
                    return songs.map { Card(song: $0, reason: genre) }
                }
            }
            var all: [[Card]] = []
            for await cards in group { all.append(cards) }
            return all
        }
        let artistCards = await fromArtists
        let genreCards = await fromGenres
        // Songs that fit but weren't asked for: one pick's radio, minus everyone already picked.
        var discovery: [Card] = []
        if let seed = artistCards.first(where: { !$0.isEmpty })?.first?.song,
           let radio = try? await music.radio(for: seed.id) {
            let pickedNames = Set(picked.map { $0.name.lowercased() })
            discovery = radio.songs.filter { !pickedNames.contains(Taste.leadArtist($0).lowercased()) && $0.id != seed.id }
                .prefix(5).map { Card(song: $0, reason: "Something new") }
        }
        let buckets = [Self.interleave(artistCards), Self.interleave(genreCards), discovery]
        var seen = Set<String>()
        deck = Self.interleave(buckets).filter { card in
            !card.song.isVideo && !library.isHidden(card.song) && !library.isLiked(card.song) && seen.insert(card.id).inserted
        }.prefix(Self.deckSize).map { $0 }
        deckIndex = 0
    }

    func answer(_ answer: Answer) {
        guard let card = current else { return }
        switch answer {
        case .skip:
            library.dropTasteSong(card.song)
            library.hide(card.song)
        case .keep:
            library.keepTasteSong(card.song)
            kept += 1
        case .love:
            library.keepTasteSong(card.song)
            if !library.isLiked(card.song) { library.setLiked(card.song, true) }
            kept += 1
            loved += 1
        }
        deckIndex += 1
    }

    // MARK: Helpers

    /// One from each list in turn, so no list takes over the front.
    static func interleave<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { out.append(list[index]) }
        }
        return out
    }

    static func unique(_ artists: [ArtistSummary]) -> [ArtistSummary] {
        var seen = Set<String>()
        return artists.filter { seen.insert($0.id).inserted }
    }
}

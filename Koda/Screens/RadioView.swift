import KodaCore
import SwiftUI

/// Stations made only from the listener's own music, as Music's Radio tab: one from everything
/// they play, one from their likes, one per top artist, one per genre picked in taste setup,
/// and a Discovery station from artists like theirs that they haven't played. Each plays a
/// mix woven from a few seed songs' radios, so it's different every time, and autoplay carries
/// it on when it runs out.
struct RadioView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var stations = Stations()
    /// The songs Your Station starts from, worked out when the page shows rather than in its
    /// body, which is drawn again every few seconds while music plays and this ranks every play.
    @State private var yourSeeds: [Song] = []

    /// The listener's top artists from Home, or the ones picked in taste setup before anything's played.
    private var artists: [ArtistSummary] {
        let home = app.home
        let played = home.yourArtists.compactMap { ref in
            ref.id.map { ArtistSummary(id: $0, name: ref.name, artwork: home.artistPhotos[$0]) }
        }
        return played.isEmpty ? library.taste.artists.filter { $0.id.hasPrefix("UC") } : played
    }

    private var discovery: [ArtistSummary] { app.home.similar.flatMap(\.artists) }
    private var hasYourStation: Bool { !yourSeeds.isEmpty }
    /// Nothing to make a station from: checked from what's cheap to read, so it never flashes up first.
    private var isEmpty: Bool {
        library.recent.isEmpty && library.liked.isEmpty && library.taste.songs.isEmpty && artists.isEmpty && library.taste.genres.isEmpty
    }

    var body: some View {
        if Platform.isMac {
            MacPage {
                MacPageTitle(title: "Radio", subtitle: "Stations made from what you play")
                content.padding(.horizontal, MacMetrics.gutter)
            }
            .navigationTitle("Radio")
        } else {
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
            }
            .navigationTitle("Radio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ProfileToolbarButton { app.isProfilePresented = true }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group { sections }
            .task(id: library.recent.first?.id) {
                let seeds = Taste(library: library, maxSeeds: 8).seeds
                yourSeeds = seeds.isEmpty ? Array((library.liked + library.taste.songs).prefix(8)) : seeds
            }
    }

    @ViewBuilder
    private var sections: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("No Stations Yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Play, like or pick some music, and stations made from it show up here.")
            } actions: {
                Button("Choose Your Taste") { app.onboarding = .taste }
                    .buttonStyle(.glass)
            }
            .frame(minHeight: 400)
        } else {
            VStack(alignment: .leading, spacing: 30) {
                topStations
                if !artists.isEmpty { artistStations }
                genreStations
            }
        }
    }

    // MARK: Your Station, Liked Songs, Discovery

    private var topStations: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
            if hasYourStation {
                StationCard(id: "you", title: "Your Station", subtitle: "Everything you play", stations: stations) {
                    PlaylistMosaic(songs: yourSeeds, size: $0)
                } seeds: { [yourSeeds] in
                    Array(yourSeeds.shuffled().prefix(4))
                }
            }
            if library.liked.count >= 5 {
                StationCard(id: "liked", title: "Liked Songs Station", subtitle: "From the songs you love", stations: stations) {
                    PlaylistMosaic(songs: library.liked, size: $0)
                } seeds: { [library] in
                    Array(library.liked.shuffled().prefix(4))
                }
            }
            if discovery.count >= 3 {
                let names = Array(discovery.prefix(2).map(\.name))
                StationCard(id: "discovery", title: "Discovery Station", subtitle: "Like \(names.joined(separator: " and "))", stations: stations) {
                    ArtistCollage(artists: Array(discovery.prefix(4)), size: $0)
                } seeds: { [app, discovery] in
                    await Stations.topSongs(of: Array(discovery.shuffled().prefix(4)), music: app.music)
                }
            }
        }
    }

    // MARK: Artists

    @ViewBuilder
    private var artistStations: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Artists' Stations", strapline: "Each artist and others like them")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(artists) { artist in
                        ArtistStationButton(artist: artist, stations: stations)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, Platform.isMac ? 0 : 20, for: .scrollContent)
            .padding(.horizontal, Platform.isMac ? 0 : -20)
        }
    }

    // MARK: Genres

    @ViewBuilder
    private var genreStations: some View {
        let genres = library.taste.genres
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Genres")
            if genres.isEmpty {
                Button("Choose Genres You Like", systemImage: "plus") { app.onboarding = .taste }
                    .buttonStyle(.glass)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(genres, id: \.self) { genre in
                        Button { stations.play("genre-\(genre)", app: app) { [app] in await Stations.genreSongs(genre, music: app.music) } } label: {
                            MoodTile(title: genre)
                                .overlay(alignment: .topTrailing) { StationBadge(isStarting: stations.starting == "genre-\(genre)").padding(10) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(genre) Station")
                    }
                }
            }
        }
    }
}

/// Starts stations, one at a time, showing which is starting.
@MainActor
@Observable
final class Stations {
    private(set) var starting: String?

    /// Plays a mix woven from the radios of the seeds `seeds` gives, leaving out what the
    /// listener asked not to be offered.
    func play(_ id: String, app: AppModel, seeds: @escaping () async -> [Song]) {
        guard starting == nil else { return }
        starting = id
        Task {
            defer { starting = nil }
            let hidden = app.library.notInterested
            let seedSongs = await seeds().filter { !hidden.hides($0) }
            guard !seedSongs.isEmpty else { return }
            let music = app.music
            let radios = await withTaskGroup(of: (Int, [Song]).self) { group in
                for (index, seed) in seedSongs.enumerated() {
                    group.addTask { (index, (try? await music.radio(for: seed.id).songs) ?? []) }
                }
                var byIndex: [Int: [Song]] = [:]
                for await (index, songs) in group { byIndex[index] = songs }
                return seedSongs.indices.map { byIndex[$0] ?? [] }
            }
            let woven = Taste.weave(radios.map { $0.filter { !hidden.hides($0) } })
            app.player.play(woven.isEmpty ? seedSongs : woven)
        }
    }

    /// Each artist's most popular song, from their page (cached, and usually already read for Home).
    nonisolated static func topSongs(of artists: [ArtistSummary], music: YouTubeMusic) async -> [Song] {
        await withTaskGroup(of: (Int, Song?).self) { group in
            for (index, artist) in artists.enumerated() {
                group.addTask { (index, try? await music.artist(artist.id).topSongs.first) }
            }
            var byIndex: [Int: Song] = [:]
            for await (index, song) in group { if let song { byIndex[index] = song } }
            return artists.indices.compactMap { byIndex[$0] }
        }
    }

    nonisolated static func genreSongs(_ genre: String, music: YouTubeMusic) async -> [Song] {
        let songs = (try? await music.search("\(genre) songs", filter: .songs).songs) ?? []
        return Array(songs.prefix(8).shuffled().prefix(4))
    }
}

/// A station's card: its covers with the radio mark, its name under them; a tap starts it.
private struct StationCard<Cover: View>: View {
    let id: String
    let title: String
    let subtitle: String
    let stations: Stations
    @ViewBuilder var cover: (CGFloat) -> Cover
    let seeds: () async -> [Song]
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { stations.play(id, app: app, seeds: seeds) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { GeometryReader { cover($0.size.width) } }
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomLeading) { StationBadge(isStarting: stations.starting == id).padding(10) }
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the station")
    }
}

/// The radio mark on a station, turning into a spinner while the station starts.
private struct StationBadge: View {
    let isStarting: Bool

    var body: some View {
        ZStack {
            if isStarting {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
        .background(.black.opacity(0.45), in: .circle)
    }
}

/// An artist's portrait, starting a station from their best-known song.
private struct ArtistStationButton: View {
    let artist: ArtistSummary
    let stations: Stations
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = "artist-\(artist.id)"
        Button {
            stations.play(id, app: app) { [app, artist] in
                // Their three best-known songs' radios, so the station is the artist and those like them.
                let page = try? await app.music.artist(artist.id)
                return Array((page?.topSongs ?? []).prefix(3))
            }
        } label: {
            VStack(spacing: 8) {
                ArtworkView(artwork: artist.artwork, size: 104, circle: true)
                    .overlay(alignment: .bottomTrailing) { StationBadge(isStarting: stations.starting == id) }
                Text(artist.name).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .frame(width: 104)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(artist.name) Station")
    }
}

/// Up to four artists' portraits in a square, for the Discovery station.
private struct ArtistCollage: View {
    let artists: [ArtistSummary]
    let size: CGFloat

    var body: some View {
        let half = size / 2
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                tile(0, half)
                tile(1, half)
            }
            GridRow {
                tile(2, half)
                tile(3, half)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
    }

    @ViewBuilder
    private func tile(_ index: Int, _ side: CGFloat) -> some View {
        if index < artists.count {
            ArtworkView(artwork: artists[index].artwork, size: side, cornerRadius: 0)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}

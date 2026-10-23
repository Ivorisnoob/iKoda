import KodaCore
import SwiftUI

/// The Mac's measurements, in one place so every page lines up with the next.
enum MacMetrics {
    /// The page's side margin, and the gap a shelf scrolls into.
    static let gutter: CGFloat = 32
    static let card: CGFloat = 176
    static let artistCard: CGFloat = 156
    static let sectionSpacing: CGFloat = 40
    /// Past this a page stops widening and centres, so lines and rows stay readable.
    static let maxContentWidth: CGFloat = 1500
}

// MARK: - Page

/// A Mac page: scrolls vertically, with the gutter on both sides and room above the player bar.
struct MacPage<Content: View>: View {
    var spacing: CGFloat = MacMetrics.sectionSpacing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .frame(maxWidth: MacMetrics.maxContentWidth, alignment: .leading)
            // A minimum of zero: nothing on a page may ask the split view for more width than
            // it has, or it floats the sidebar over the page and the page runs off the window.
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
    }
}

/// A page's own title, as large as the window's content calls for, above what it lists.
struct MacPageTitle<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, MacMetrics.gutter)
        .accessibilityAddTraits(.isHeader)
    }
}

extension MacPageTitle where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Cards

/// A cover with its title under it. Under the pointer the cover lifts and, when the card
/// can play, a play button rises in its corner, as in Music.
struct MacCoverCard<Cover: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = MacMetrics.card
    var circle = false
    var onPlay: (() -> Void)?
    @ViewBuilder var cover: () -> Cover
    @State private var hovering = false

    var body: some View {
        VStack(alignment: circle ? .center : .leading, spacing: 8) {
            cover()
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(hovering ? 0.26 : 0.1), radius: hovering ? 14 : 5, y: hovering ? 8 : 2)
                .overlay(alignment: .bottomTrailing) {
                    if let onPlay, hovering {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .padding(10)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                        .help("Play")
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)
            VStack(alignment: circle ? .center : .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: circle ? .center : .leading)
        }
        .frame(width: width)
        .contentShape(.rect)
        .onHover { over in
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { hovering = over }
        }
    }
}

extension MacCoverCard where Cover == ArtworkView {
    init(artwork: Artwork?, title: String, subtitle: String?, width: CGFloat = MacMetrics.card, circle: Bool = false, onPlay: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, width: width, circle: circle, onPlay: onPlay) {
            ArtworkView(artwork: artwork, size: width, cornerRadius: circle ? 0 : 10, circle: circle)
        }
    }
}

/// Any music item as a Mac card: songs play, everything else opens; albums and playlists
/// also play straight from the card.
struct MacItemCard: View {
    let item: MusicItem
    var width: CGFloat = MacMetrics.card
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        switch item {
        case .song(let song):
            Button { player.startRadio(from: song) } label: {
                MacCoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine, width: width,
                             onPlay: { player.startRadio(from: song) })
            }
            .buttonStyle(.plain)
            .contextMenu { SongMenuItems(song: song) }
        case .album(let album):
            NavigationLink(value: Route.album(album)) {
                MacCoverCard(artwork: album.artwork, title: album.title, subtitle: album.cardSubtitle, width: width,
                             onPlay: { app.playCollection(.album(album)) })
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlist)) {
                MacCoverCard(artwork: playlist.artwork, title: playlist.title, subtitle: playlist.subtitle, width: width,
                             onPlay: { app.playCollection(.playlist(playlist)) })
            }
            .buttonStyle(.plain)
        case .artist(let artist):
            MacArtistCard(artist: artist, width: width * 0.88)
        }
    }
}

/// An artist's round portrait and name, opening their page.
struct MacArtistCard: View {
    let artist: ArtistSummary
    var width: CGFloat = MacMetrics.artistCard

    var body: some View {
        NavigationLink(value: Route.artist(artist)) {
            MacCoverCard(artwork: artist.artwork, title: artist.name, subtitle: artist.subtitle, width: width, circle: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shelf

/// A titled row that scrolls sideways, with paging arrows by its title instead of a
/// swipe a mouse can't make, and See All when there is more than the row shows.
struct MacShelf<Content: View>: View {
    let title: String
    var subtitle: String?
    var seeAll: Route?
    @ViewBuilder var content: () -> Content

    @State private var position = ScrollPosition()
    @State private var offset: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    private var canGoBack: Bool { offset > 1 }
    private var canGoForward: Bool { offset + visibleWidth < contentWidth - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                MacSectionTitle(title: title, subtitle: subtitle, seeAll: seeAll)
                Spacer(minLength: 0)
                if canGoBack || canGoForward {
                    HStack(spacing: 4) {
                        pageButton("chevron.left", help: "Back", enabled: canGoBack) { page(-1) }
                        pageButton("chevron.right", help: "More", enabled: canGoForward) { page(1) }
                    }
                }
            }
            .padding(.horizontal, MacMetrics.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .scrollPosition($position)
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, MacMetrics.gutter, for: .scrollContent)
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.x + geometry.contentInsets.leading, geometry.containerSize.width, geometry.contentSize.width]
            } action: { _, values in
                offset = values[0]
                visibleWidth = values[1]
                contentWidth = values[2]
            }
        }
    }

    private func page(_ direction: CGFloat) {
        let step = max(visibleWidth - MacMetrics.gutter * 2 - 40, 200)
        let target = min(max(0, offset + direction * step), max(0, contentWidth - visibleWidth))
        withAnimation(.spring(response: 0.45, dampingFraction: 1)) {
            position.scrollTo(x: target - MacMetrics.gutter)
        }
    }

    private func pageButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .help(help)
    }
}

/// A section's title, opening See All when there is one.
struct MacSectionTitle: View {
    let title: String
    var subtitle: String?
    var seeAll: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.title2.bold())
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("See All").font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A browse shelf of any items, from YouTube's own pages.
struct MacItemShelf: View {
    let shelf: Shelf

    var body: some View {
        MacShelf(title: shelf.title, subtitle: shelf.strapline, seeAll: shelf.items.count > 8 ? .shelf(shelf) : nil) {
            ForEach(shelf.items) { item in
                MacItemCard(item: item)
            }
        }
    }
}

/// Items in a grid that fills the width, the way a library or See All page lays out on the Mac.
struct MacGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var minimum: CGFloat = MacMetrics.card
    @ViewBuilder var cell: (Item, CGFloat) -> Cell
    @State private var width: CGFloat = 800

    var body: some View {
        let spacing: CGFloat = 22
        let available = max(width - MacMetrics.gutter * 2, minimum)
        let columns = max(1, Int((available + spacing) / (minimum + spacing)))
        let side = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing, alignment: .top), count: columns),
                  alignment: .leading, spacing: 28) {
            ForEach(items) { item in cell(item, side) }
        }
        .padding(.horizontal, MacMetrics.gutter)
        // Measured here, a flexible frame that reports no minimum, rather than on the grid:
        // columns fixed to the last width measured would hold the grid at that width, so it
        // could never be measured narrower when the sidebar comes back.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Collection header

/// The top of an album or playlist on the Mac: the cover on the left, and beside it what it
/// is, its title, who made it and what to do with it, as Music lays it out. Buttons keep
/// their own size rather than stretching across the window.
struct MacCollectionHeader<Cover: View, Actions: View>: View {
    var kind: String?
    let title: String
    var byline: String?
    var bylineArtists: [ArtistRef] = []
    var openArtist: (ArtistSummary) -> Void = { _ in }
    var detail: String?
    var description: String?
    var accent: Color = .accentColor
    var shuffleTitle = "Shuffle"
    var canPlay = true
    let play: () -> Void
    let shuffle: () -> Void
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var actions: () -> Actions

    @State private var showsDescription = false
    @State private var width: CGFloat = 900
    @Environment(\.colorScheme) private var colorScheme

    /// A narrow window keeps the cover beside the title, smaller.
    private var coverSide: CGFloat { width < 620 ? 150 : 232 }

    var body: some View {
        HStack(alignment: .bottom, spacing: width < 620 ? 20 : 28) {
            cover()
                .frame(width: coverSide, height: coverSide)
                .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
            VStack(alignment: .leading, spacing: 0) {
                if let kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.bottom, 4)
                }
                Text(title)
                    .font(.system(size: width < 620 ? 24 : 32, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                if let byline, !byline.isEmpty {
                    let opens = !ArtistRef.linked(bylineArtists).isEmpty
                    ArtistLinks(line: byline, artists: bylineArtists, open: openArtist) {
                        Text(byline)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(opens ? accent.readable(in: colorScheme) : .secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                if let description, !description.isEmpty {
                    Button { showsDescription = true } label: {
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(description)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("More").fontWeight(.semibold).foregroundStyle(.primary)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .popover(isPresented: $showsDescription) {
                        ScrollView {
                            Text(description)
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding(20)
                        }
                        .frame(width: 420)
                        .frame(maxHeight: 420)
                    }
                }
                HStack(spacing: 10) {
                    MacPlayButtons(shuffleTitle: shuffleTitle, play: play, shuffle: shuffle)
                        .disabled(!canPlay)
                    actions()
                }
                .padding(.top, width < 620 ? 12 : 18)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MacMetrics.gutter)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Play and Shuffle (or Radio) at their natural width: a filled button for the main action,
/// a glass one beside it.
struct MacPlayButtons: View {
    var shuffleTitle = "Shuffle"
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            Button(action: shuffle) {
                Label(shuffleTitle, systemImage: shuffleTitle == "Shuffle" ? "shuffle" : "dot.radiowaves.left.and.right")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
        .font(.body.weight(.semibold))
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

/// A round glass button for a header's secondary actions: add, download, more.
struct MacIconButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .controlSize(.large)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
    }
}

extension Color {
    /// This colour, made readable as text on the page: a colourless one gives way to the
    /// accent, dark mode lightens a deep one and light mode darkens a bright one.
    func readable(in scheme: ColorScheme) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a), s >= 0.2 else { return .accentColor }
        return scheme == .dark
            ? Color(hue: h, saturation: min(s, 0.7), brightness: max(b, 0.85))
            : Color(hue: h, saturation: max(s, 0.6), brightness: min(b, 0.5))
    }
}

// MARK: - Track list

/// Songs as a Mac list: columns for title, artist, album and time, a stripe on every other
/// row, the row under the pointer lit, a double-click to play, and the number turning into a
/// play button on hover, as in Music.
struct MacTrackList: View {
    let songs: [Song]
    /// Track numbers instead of covers, for an album.
    var numbered = false
    var showsArtist = true
    var showsAlbum = true
    let play: (Int) -> Void
    /// A row came on screen, for loading the next page of a long playlist.
    var onRowAppear: ((Int) -> Void)?
    /// Extra items at the top of each row's menu, such as Remove from Playlist.
    var rowMenu: ((Int) -> AnyView)?

    @State private var width: CGFloat = 900

    var body: some View {
        // Columns give way as the window narrows: the album first, then the artist.
        let album = showsAlbum && width > 760
        let artist = showsArtist && width > 520
        VStack(spacing: 0) {
            MacTrackHeader(numbered: numbered, showsArtist: artist, showsAlbum: album)
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    MacTrackRow(song: song, index: index, numbered: numbered, showsArtist: artist, showsAlbum: album,
                                play: { play(index) }, extraMenu: rowMenu?(index))
                        .onAppear { onRowAppear?(index) }
                }
            }
        }
        .padding(.horizontal, MacMetrics.gutter - 12)
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct MacTrackHeader: View {
    let numbered: Bool
    let showsArtist: Bool
    let showsAlbum: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(numbered ? "#" : "").frame(width: numbered ? 28 : 40, alignment: numbered ? .trailing : .leading)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                if showsArtist { Text("Artist").frame(maxWidth: .infinity, alignment: .leading) }
                if showsAlbum { Text("Album").frame(maxWidth: .infinity, alignment: .leading) }
                Color.clear.frame(width: 40)
                Image(systemName: "clock").frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 28)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider().padding(.horizontal, 12)
        }
        .accessibilityHidden(true)
    }
}

private struct MacTrackRow: View {
    let song: Song
    let index: Int
    let numbered: Bool
    let showsArtist: Bool
    let showsAlbum: Bool
    let play: () -> Void
    var extraMenu: AnyView?

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var hovering = false

    private var isCurrent: Bool { player.current?.id == song.id }

    var body: some View {
        HStack(spacing: 14) {
            leading
            HStack(spacing: 6) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if song.isVideo {
                    Image(systemName: "play.rectangle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Music video")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsArtist {
                ArtistLinks(line: song.artistLine, artists: song.artists, open: { app.open(.artist($0)) }) {
                    Text(song.artistLine).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsAlbum {
                Group {
                    if let album = song.album {
                        Button {
                            app.open(.album(AlbumSummary(id: album.id, title: album.title, artistLine: song.artistLine,
                                                         artists: song.artists, artwork: song.artwork)))
                        } label: {
                            Text(album.title).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                DownloadIndicator(song: song)
                likeButton
            }
            .frame(width: 40, alignment: .trailing)
            Text(duration)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            MacMoreMenu(size: 28, isGlass: false) {
                if let extraMenu { extraMenu }
                SongMenuItems(song: song)
            }
            .opacity(hovering ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: numbered ? 40 : 52)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.08 : (index.isMultiple(of: 2) ? 0.03 : 0)))
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: play)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play", systemImage: "play") { play() }
            if let extraMenu { extraMenu }
            SongMenuItems(song: song)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play", play)
    }

    @ViewBuilder
    private var leading: some View {
        let playButton = Button(action: play) {
            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
        }
        .buttonStyle(.plain)
        .help("Play")
        if numbered {
            ZStack {
                if hovering, !isCurrent {
                    playButton
                } else if isCurrent {
                    NowPlayingBars(isPlaying: player.wantsToPlay).font(.callout)
                } else {
                    Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .trailing)
        } else {
            ArtworkView(artwork: song.artwork, size: 40, cornerRadius: 5)
                .overlay {
                    if hovering || isCurrent {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                        if hovering, !isCurrent {
                            playButton.foregroundStyle(.white)
                        } else {
                            NowPlayingBars(isPlaying: player.wantsToPlay).font(.callout).foregroundStyle(.white)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var likeButton: some View {
        let liked = library.isLiked(song)
        if liked || hovering {
            Button { library.toggleLike(song) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liked ? Color.pink : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(liked ? "Remove from Liked" : "Like")
        }
    }

    private var duration: String {
        guard let d = song.duration else { return "" }
        return Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// A song as a compact tile, cover beside title and artist, for grids like Quick picks and
/// an artist's top songs. A click plays; the cover shows play under the pointer.
struct MacSongTile: View {
    let song: Song
    let play: () -> Void
    @Environment(Player.self) private var player
    @State private var hovering = false

    private var isCurrent: Bool { player.current?.id == song.id }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ArtworkView(artwork: song.artwork, size: 46, cornerRadius: 6)
                    .overlay {
                        if hovering || isCurrent {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                            if isCurrent {
                                NowPlayingBars(isPlaying: player.wantsToPlay).foregroundStyle(.white)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    Text(song.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                MacMoreMenu(size: 28, isGlass: false) { SongMenuItems(song: song) }
                    .opacity(hovering ? 1 : 0)
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { SongMenuItems(song: song) }
    }
}

/// A square of colour with a symbol, standing in for a cover where a list has none of its own.
struct MacSymbolCover: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 232

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            .frame(width: size, height: size)
    }
}

/// The Mac's ••• menu. Catalyst draws a SwiftUI `Menu` as a pull-down button, a pill with a
/// chevron, unless the menu is a plain button; so the label here is drawn by Koda, a glass
/// circle in headers and bare dots in rows, and Catalyst adds nothing around it.
struct MacMoreMenu<Items: View>: View {
    var size: CGFloat = 38
    var isGlass = true
    @ViewBuilder var items: () -> Items
    @State private var hovering = false

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: isGlass ? 15 : 13, weight: .semibold))
                .foregroundStyle(isGlass ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .background {
                    if isGlass {
                        Circle().fill(.clear).glassEffect(.regular, in: .circle)
                    } else {
                        Circle().fill(.primary.opacity(hovering ? 0.08 : 0))
                    }
                }
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("More")
        .accessibilityLabel("More")
    }
}

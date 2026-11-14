import KodaCore
import SwiftUI

/// A titled, horizontally scrolling row of cards.
struct ShelfView<Content: View>: View {
    let title: String
    var strapline: String?
    var seeAll: Route?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, strapline: strapline, seeAll: seeAll)
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var strapline: String?
    var seeAll: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let strapline {
                Text(strapline)
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            if let seeAll {
                NavigationLink(value: seeAll) {
                    HStack(spacing: 4) {
                        Text(title).font(.scaled(.title3).bold())
                        Image(systemName: "chevron.right")
                            .font(.scaled(.subheadline).weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.scaled(.title3).bold())
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A shelf of any music items, from a browse response.
struct ItemShelf: View {
    let shelf: Shelf
    var onPlay: (Song) -> Void

    var body: some View {
        ShelfView(title: shelf.title, strapline: shelf.strapline, seeAll: shelf.items.count > 6 ? .shelf(shelf) : nil) {
            ForEach(shelf.items) { item in
                ItemCard(item: item, onPlay: onPlay)
            }
        }
    }
}

/// Songs in columns of four rows that page sideways, the way Quick picks are laid out.
struct SongColumnsShelf: View {
    let title: String
    var strapline: String?
    let songs: [Song]
    var onPlay: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, strapline: strapline)
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(60), spacing: 0), count: min(4, max(1, songs.count))), spacing: 20) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        SongRow(song: song) { onPlay(index) }
                            .containerRelativeFrame(.horizontal) { width, _ in width - 64 }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }
}

import AppIntents
import SwiftUI
import WidgetKit

// The songs the listener played last, as covers on the newest one's colours; a tap on any of
// them plays it again (autoplay carries on after). Written by the app (`WidgetBridge`).

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    var snapshot: ListeningSnapshot?
}

struct RecentlyPlayedProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentlyPlayedEntry { RecentlyPlayedEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        let snapshot = ListeningSnapshot.load()
        completion(RecentlyPlayedEntry(date: .now, snapshot: snapshot?.recent.isEmpty == false ? snapshot : context.isPreview ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        completion(Timeline(entries: [RecentlyPlayedEntry(date: .now, snapshot: ListeningSnapshot.load())], policy: .never))
    }
}

extension ListeningSnapshot {
    /// The widget gallery's stand-in, before anything has played.
    static let preview = ListeningSnapshot(
        recent: (1...6).map { WidgetSong(id: "preview-\($0)", title: "Song \($0)", artist: "Koda") },
        recentColors: nil, days: [WidgetDay.key(.now): 47 * 60], streak: 5, streakEnds: WidgetDay.key(.now),
        topArtist: "Your Top Artist", topArtistPlays: 23)
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningSnapshot.recentKind, provider: RecentlyPlayedProvider()) { entry in
            RecentlyPlayedView(entry: entry)
        }
        .configurationDisplayName("Recently Played")
        .description("The songs you played last. Tap one to hear it again.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct RecentlyPlayedView: View {
    let entry: RecentlyPlayedEntry
    @Environment(\.widgetFamily) private var family

    private var songs: [WidgetSong] { entry.snapshot?.recent ?? [] }

    var body: some View {
        Group {
            if songs.isEmpty {
                empty
            } else {
                switch family {
                case .systemMedium: medium
                case .systemLarge: large
                default: small
                }
            }
        }
        .foregroundStyle(.white)
        .padding(family == .systemSmall ? 12 : 16)
        .containerBackground(for: .widget) { CoverBackground(colors: entry.snapshot?.recentColors) }
    }

    /// Four covers, two by two, each its own button.
    private var small: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                cover(at: 0)
                cover(at: 1)
            }
            GridRow {
                cover(at: 2)
                cover(at: 3)
            }
        }
    }

    /// A row of four, each with its title.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetEyebrow(title: "Recently Played", systemImage: "clock.arrow.circlepath")
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    tile(at: index, showsArtist: false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Two rows of three, each with its title and artist.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetEyebrow(title: "Recently Played", systemImage: "clock.arrow.circlepath")
            Grid(horizontalSpacing: 12, verticalSpacing: 14) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(0..<3, id: \.self) { column in
                            tile(at: row * 3 + column, showsArtist: true)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetEyebrow(title: "Recently Played", systemImage: "clock.arrow.circlepath")
            Spacer(minLength: 0)
            Image(systemName: "music.note.list")
                .font(.title.weight(.semibold))
                .padding(.bottom, 4)
            Text("Nothing Yet")
                .font(.headline.weight(.bold))
            Text("Songs you play in Koda show up here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Parts

    /// A cover that plays its song, or an empty square holding the place.
    @ViewBuilder
    private func cover(at index: Int) -> some View {
        if songs.indices.contains(index) {
            let song = songs[index]
            Button(intent: PlayRecentSongIntent(songId: song.id)) {
                WidgetCover(name: song.cover, radius: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(song.title) by \(song.artist)")
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.08))
                .aspectRatio(1, contentMode: .fit)
        }
    }

    @ViewBuilder
    private func tile(at index: Int, showsArtist: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            cover(at: index)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
            if songs.indices.contains(index) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(songs[index].title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if showsArtist {
                        Text(songs[index].artist)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import KodaCore
import SwiftUI

/// Every play, newest first, under the day it happened: Recently Played keeps one row per song,
/// this keeps each time. A play can be removed on its own; a song with none left leaves Recently
/// Played too.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var confirmsClear = false

    /// Plays grouped by calendar day, newest day first.
    private var days: [(day: Date, plays: [PlayEvent])] {
        let calendar = Calendar.current
        var result: [(day: Date, plays: [PlayEvent])] = []
        for event in library.history {
            let day = calendar.startOfDay(for: event.date)
            if result.last?.day == day {
                result[result.count - 1].plays.append(event)
            } else {
                result.append((day, [event]))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if Platform.isMac { macBody } else { phoneBody }
        }
        .navigationTitle("History")
        .confirmationDialog("Clear your listening history?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        } message: {
            Text("Recently Played and Quick picks start over. Liked songs and stats stay.")
        }
    }

    private var phoneBody: some View {
        List {
            ForEach(days, id: \.day) { day in
                Section(Self.title(for: day.day)) {
                    let songs = day.plays.map(\.song)
                    ForEach(Array(day.plays.enumerated()), id: \.element.id) { index, event in
                        SongRow(song: event.song, subtitle: "\(event.song.artistLine) · \(event.date.formatted(date: .omitted, time: .shortened))") {
                            player.play(songs, startAt: index)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                        .swipeActions(edge: .leading) {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([event.song]) }
                                .tint(.indigo)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                withAnimation { library.removeFromHistory(event.id) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.history.isEmpty { emptyState }
        }
        .toolbar {
            if !library.history.isEmpty {
                Button("Clear", role: .destructive) { confirmsClear = true }
            }
        }
    }

    private var macBody: some View {
        let days = days
        let all = library.history.map(\.song)
        return MacPage(spacing: 28) {
            MacCollectionHeader(
                kind: "Library",
                title: "History",
                detail: all.isEmpty ? nil : (all.count == 1 ? "1 play" : "\(all.count) plays"),
                canPlay: !all.isEmpty,
                play: { player.play(Array(all.prefix(200))) },
                shuffle: { player.play(Array(all.prefix(200)), startAt: Int.random(in: 0..<max(min(all.count, 200), 1)), shuffled: true) }
            ) { side in
                MacSymbolCover(systemImage: "clock.arrow.circlepath", tint: .orange, size: side)
            } actions: {
                if !all.isEmpty {
                    Button("Clear History", role: .destructive) { confirmsClear = true }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
            if days.isEmpty {
                emptyState.frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ForEach(days, id: \.day) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        MacSectionTitle(title: Self.title(for: day.day))
                        let songs = day.plays.map(\.song)
                        MacTrackList(songs: songs, showsAlbum: false, play: { player.play(songs, startAt: $0) }, rowMenu: { index in
                            let event = day.plays[index]
                            return AnyView(Button("Remove from History", systemImage: "trash", role: .destructive) {
                                library.removeFromHistory(event.id)
                            })
                        })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("Nothing Played Yet", systemImage: "clock.arrow.circlepath",
                               description: Text(app.settings.savesListeningHistory
                                                 ? "Each song you play appears here, under the day you played it."
                                                 : "Listening history is off, so songs you play aren't kept."))
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.day().month(.wide).year())
    }
}

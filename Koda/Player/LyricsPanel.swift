import KodaCore
import SwiftUI

/// Lyrics for the playing song: synced ones follow the song (word by word when the
/// provider has word timing) and a tap on a line seeks to it.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var state: LoadState<Lyrics?> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                LyricsLoading()
            case .failed, .loaded(nil):
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("Lyrics for this song aren't available."))
                    .foregroundStyle(.primary)
            case .loaded(.plain(let text)?):
                ScrollView {
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            case .loaded(.synced(let lines)?):
                SyncedLyrics(lines: lines)
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: LyricsRequest(songId: player.current?.id, sources: app.settings.lyricsSources)) {
            guard let song = player.current else { return }
            state = .loading
            let found = await app.lyrics.lyrics(for: song, sources: app.settings.lyricsSources)
            guard player.current?.id == song.id else { return }
            state = .loaded(found)
        }
    }
}

/// What the panel looks lyrics up for; a change of song or of sources looks again.
private struct LyricsRequest: Equatable {
    var songId: String?
    var sources: [LyricsSource]
}

import KodaCore
import SwiftUI

/// The songs and artists the listener asked Koda to suggest less (`NotInterestedMenu`), each
/// with a way back. They stay out of Home, mixes, radio and autoplay; songs picked by hand play.
struct SuggestLessView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let hidden = library.notInterested
        Form {
            if !hidden.artists.isEmpty {
                Section("Artists") {
                    ForEach(hidden.artists, id: \.self) { artist in
                        Text(artist.name)
                            .swipeActions {
                                Button("Suggest Again", systemImage: "hand.thumbsup") {
                                    withAnimation { library.unhide(artist: artist) }
                                }
                                .tint(.accentColor)
                            }
                    }
                }
            }
            if !hidden.songs.isEmpty {
                Section("Songs") {
                    ForEach(hidden.songs) { song in
                        HStack(spacing: 12) {
                            ArtworkView(artwork: song.artwork, size: 40, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button("Suggest Again", systemImage: "hand.thumbsup") {
                                withAnimation { library.unhide(song) }
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
        }
        .overlay {
            if hidden.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "hand.thumbsdown",
                                       description: Text("Choose Suggest Less on a song to keep it, or its artist, out of Home, mixes, radio and autoplay."))
            }
        }
        .navigationTitle("Suggest Less")
    }
}

/// The Mac's Settings list of the same, in the History & Privacy pane.
struct MacSuggestLessGroup: View {
    @Environment(Library.self) private var library

    var body: some View {
        let hidden = library.notInterested
        MacSettingsGroup(title: "Suggest less",
                         footer: hidden.isEmpty
                             ? "Choose Suggest Less on a song to keep it, or its artist, out of Home, mixes, radio and autoplay."
                             : "Kept out of Home, mixes, radio and autoplay. Songs you pick yourself still play.") {
            ForEach(hidden.artists, id: \.self) { artist in
                MacSettingsRow(title: artist.name, detail: "Artist") {
                    Button("Suggest Again") { library.unhide(artist: artist) }
                }
            }
            ForEach(hidden.songs) { song in
                MacSettingsRow(title: song.title, detail: song.artistLine) {
                    Button("Suggest Again") { library.unhide(song) }
                }
            }
            if hidden.isEmpty {
                MacSettingsRow(title: "Nothing here yet") { EmptyView() }
            }
        }
    }
}

#if os(iOS)
import KodaCore
import SwiftUI

/// Selecting several songs in a list, as Mail and Files select: the list goes into edit mode
/// with the system's selection circles, the tab bar steps away, and a bar along the bottom acts
/// on what's selected (Play Next, Add to Queue, Add to Playlist, Download, and taking them out
/// of this list where it can). An action ends the selection.
///
/// The list itself is a `List(selection:)` over the songs' ids; its rows stop taking taps while
/// selecting (`allowsHitTesting`), so a tap selects instead of playing.
struct SongSelectionBar: ViewModifier {
    @Binding var selection: Set<String>
    @Binding var editMode: EditMode
    /// The songs listed, in order: the selected play and are added in this order.
    let songs: [Song]
    var showsDownload = true
    /// Taking the selected out of this list; nil where a list can't (Recently Played).
    var removal: Removal?

    struct Removal {
        let title: String
        let systemImage: String
        let perform: ([Song]) -> Void
    }

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads

    func body(content: Content) -> some View {
        content
            .environment(\.editMode, $editMode)
            .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
            .toolbar {
                if editMode.isEditing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { act { player.playNext($0) } }
                        Spacer()
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { act { player.addToQueue($0) } }
                        Spacer()
                        Button("Add to Playlist", systemImage: "text.badge.plus") { act { app.addToPlaylist($0) } }
                        if showsDownload {
                            Spacer()
                            Button("Download", systemImage: "arrow.down.circle") { act { downloads.download($0) } }
                        }
                        if let removal {
                            Spacer()
                            Button(removal.title, systemImage: removal.systemImage, role: .destructive) { act(removal.perform) }
                        }
                    }
                }
            }
            // Leaving edit mode any way (Done, an action) forgets what was selected.
            .onChange(of: editMode.isEditing) { _, editing in
                if !editing { selection = [] }
            }
    }

    private func act(_ action: ([Song]) -> Void) {
        let chosen = songs.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        action(chosen)
        withAnimation { editMode = .inactive }
    }
}
#endif

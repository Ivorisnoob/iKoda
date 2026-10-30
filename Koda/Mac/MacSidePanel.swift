import KodaCore
import SwiftUI

/// What the Mac shows beside the page: the playing song's lyrics or what plays next.
enum MacSidePanel: Hashable {
    case lyrics, queue
}

/// Lyrics or Up Next beside the page, as Music shows them on the Mac: one at a time, switched
/// at the top or from the player bar's buttons (the same button again closes it), while the page
/// stays as it was. On the song's own colours, as Now Playing draws the same two panels.
struct MacSidePanelView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 12) {
            Picker("Show", selection: Binding(get: { app.sidePanel ?? .lyrics }, set: { app.sidePanel = $0 })) {
                Text("Lyrics").tag(MacSidePanel.lyrics)
                Text("Up Next").tag(MacSidePanel.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Group {
                if app.sidePanel == .queue { QueuePanel() } else { LyricsPanel() }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            MeshBackground(palette: app.nowPlayingPalette.palette, isAnimating: false)
                .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

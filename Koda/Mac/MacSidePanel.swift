import KodaCore
import SwiftUI

/// What the Mac shows beside the page: the playing song's lyrics or what plays next.
enum MacSidePanel: Hashable {
    case lyrics, queue
}

/// Lyrics or Up Next beside the page, as Music shows them on the Mac: one at a time, switched
/// at the top or from the player bar's buttons (the same button again closes it), while the page
/// stays as it was. In the window's own appearance, as Music's panels are; Now Playing
/// draws the same two panels on the song's colours.
struct MacSidePanelView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    /// The window's toolbar band over the panel: the switch sits in it, level with the window's
    /// top row, where search used to be. Not a toolbar item: the toolbar never changes at runtime.
    @State private var toolbarHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: Binding(get: { app.sidePanel ?? .lyrics }, set: { app.sidePanel = $0 })) {
                Text("Lyrics").tag(MacSidePanel.lyrics)
                Text("Up Next").tag(MacSidePanel.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .frame(height: toolbarHeight)
            Group {
                if app.sidePanel == .queue { QueuePanel() } else { LyricsPanel() }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if $0 > 0 { toolbarHeight = $0 } }
        .ignoresSafeArea(.container, edges: .top)
    }
}

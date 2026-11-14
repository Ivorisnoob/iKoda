#if os(macOS)
import AppKit
import KodaCore
import SwiftUI

/// Music's Mini Player: the cover in a small window of its own that floats over other apps,
/// with the song and its controls rising over the cover while the pointer is on it (or while
/// paused). Window → Mini Player, ⌥⌘M.
struct MacMiniPlayerView: View {
    static let windowID = "miniPlayer"
    static let side: CGFloat = 300
    @Environment(Player.self) private var player
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if player.current != nil {
                // Filling the window, whatever size it's dragged to.
                ArtworkView(artwork: player.current?.artwork, size: Self.side * 2, cornerRadius: 0, fillsFrame: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
                if showsControls {
                    controls
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                ContentUnavailableView("Not Playing", systemImage: "music.note",
                                       description: Text("Songs you play show here."))
            }
        }
        // Under the hidden title bar too: the window is the cover, its buttons over it.
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.3), value: showsControls)
        .animation(.smooth(duration: 0.3), value: player.current?.id)
    }

    private var showsControls: Bool { hovering || !player.wantsToPlay }

    private var controls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.scaled(.callout).weight(.semibold))
                Text(player.current?.artistLine ?? "")
                    .font(.scaled(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            BarProgress()
            HStack(spacing: 26) {
                Button("Previous", systemImage: "backward.fill") { player.previous() }
                PlayPauseButton(size: 22)
                Button("Next", systemImage: "forward.fill") { player.next() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.scaledSystem(size: 17))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(10)
    }
}

/// The Dock icon's menu, as Music's: the song playing, then Play or Pause, Next and Previous.
final class KodaMacAppDelegate: NSObject, NSApplicationDelegate {
    /// Set as the app starts; the delegate is made by SwiftUI, before the app's objects exist.
    @MainActor static weak var model: AppModel?

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let player = Self.model?.player else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let song = player.current {
            for line in [song.title, song.artistLine] where !line.isEmpty {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let hasSong = player.current != nil
        menu.addItem(item(player.wantsToPlay ? "Pause" : "Play", #selector(playPause), enabled: hasSong))
        menu.addItem(item("Next", #selector(next), enabled: hasSong))
        menu.addItem(item("Previous", #selector(previous), enabled: hasSong))
        return menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @MainActor @objc private func playPause() { Self.model?.player.togglePlayPause(from: "the Dock") }
    @MainActor @objc private func next() { Self.model?.player.next() }
    @MainActor @objc private func previous() { Self.model?.player.previous() }
}
#endif

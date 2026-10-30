import SwiftUI
import UIKit

/// A full-screen video on the Mac is a window of its own, as QuickTime Player's and TV's are:
/// made for the video without a title or toolbar, taken into macOS full screen in a Space of its
/// own, and closed when the video leaves full screen. The main window is never touched, so its
/// toolbar (back, search, the sidebar button) stays as it is, in full screen too, and the video
/// is nothing but the picture and its controls.
///
/// It lives exactly as long as `VideoPlayback.isFullScreen`: MacRootView opens it when that turns
/// on, and it closes itself when that turns off. Leaving macOS full screen (the green button,
/// ⌃⌘F) or closing it (⌘W) turns it off.
struct MacVideoWindow: View {
    static let windowID = "video"
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var window = FullScreenWindow()

    var body: some View {
        ZStack {
            Color.black
            // Only while full screen: a window the system restores at launch closes at once,
            // without going full screen first.
            if model.videos.isFullScreen, let video = model.videos.current {
                FullScreenVideoView(playback: model.videos, video: video)
                    .background(WindowReader { window.adopt($0) })
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.videos.isFullScreen, initial: true) { _, isFullScreen in
            if !isFullScreen { dismissWindow(id: Self.windowID, value: Self.windowID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { note in
            window.becameKey(note.object)
        }
        .onReceive(NotificationCenter.default.publisher(for: FullScreenWindow.didExitFullScreen)) { note in
            if window.isWindow(note.object) { model.videos.isFullScreen = false }
        }
        .onDisappear { model.videos.isFullScreen = false }
    }
}

/// The video window's own AppKit window, reached the one way Catalyst allows: it is the key
/// window the moment its UIWindow becomes key. AppKit's `toggleFullScreen:` (what the green button
/// sends) takes it into full screen; UIKit has no call for that.
@MainActor
final class FullScreenWindow {
    static let didExitFullScreen = Notification.Name("NSWindowDidExitFullScreenNotification")
    private weak var window: UIWindow?
    private weak var appKitWindow: NSObject?

    /// The window as it's made: only the picture, no title and no toolbar, set once.
    func adopt(_ window: UIWindow) {
        guard self.window !== window else { return }
        self.window = window
        #if targetEnvironment(macCatalyst)
        window.windowScene?.titlebar?.titleVisibility = .hidden
        window.windowScene?.titlebar?.toolbar = nil
        #endif
        if window.isKeyWindow { enterFullScreen() }
    }

    func becameKey(_ object: Any?) {
        guard let window, (object as? UIWindow) === window, appKitWindow == nil else { return }
        enterFullScreen()
    }

    func isWindow(_ object: Any?) -> Bool {
        guard let appKitWindow else { return false }
        return (object as AnyObject?) === appKitWindow
    }

    private func enterFullScreen() {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let key = app.value(forKey: "keyWindow") as? NSObject else { return }
        appKitWindow = key
        // NSWindow.StyleMask.fullScreen
        let mask = key.value(forKey: "styleMask") as? UInt ?? 0
        if mask & (1 << 14) == 0 { key.perform(NSSelectorFromString("toggleFullScreen:"), with: nil) }
    }
}

/// Hands over the UIWindow a view lands in.
private struct WindowReader: UIViewRepresentable {
    let found: (UIWindow) -> Void

    func makeUIView(context: Context) -> Probe { Probe(found: found) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        let found: (UIWindow) -> Void

        init(found: @escaping (UIWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { found(window) }
        }
    }
}

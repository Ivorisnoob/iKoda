import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        .onReceive(NotificationCenter.default.publisher(for: FullScreenWindow.didBecomeKey)) { note in
            window.becameKey(note.object)
        }
        .onReceive(NotificationCenter.default.publisher(for: FullScreenWindow.didExitFullScreen)) { note in
            if window.isWindow(note.object) { model.videos.isFullScreen = false }
        }
        .onDisappear { model.videos.isFullScreen = false }
    }
}

#if os(macOS)
/// The video window's own window, taken into macOS full screen as it's made: only the picture,
/// no title and no toolbar.
@MainActor
final class FullScreenWindow {
    static let didBecomeKey = NSWindow.didBecomeKeyNotification
    static let didExitFullScreen = NSWindow.didExitFullScreenNotification
    private weak var window: NSWindow?

    func adopt(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.backgroundColor = .black
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Nothing to find: the window is handed over directly.
    func becameKey(_ object: Any?) {}

    func isWindow(_ object: Any?) -> Bool {
        guard let window else { return false }
        return (object as AnyObject?) === window
    }
}

/// Hands over the NSWindow a view lands in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
#else
/// The video window's own AppKit window, taken into full screen with AppKit's `toggleFullScreen:`
/// (what the green button sends): UIKit has no call for it. Catalyst gives no public way from a
/// UIWindow to its NSWindow, so it's recognised as it becomes key by its frame, which is the
/// scene's own. Never "the key window": as the new window became key, AppKit could still name
/// the main window, which then went full screen instead.
@MainActor
final class FullScreenWindow {
    static let didBecomeKey = Notification.Name("NSWindowDidBecomeKeyNotification")
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
    }

    /// An AppKit window became key: if it's this one, the first time, into full screen it goes.
    func becameKey(_ object: Any?) {
        guard appKitWindow == nil, let candidate = object as? NSObject, isHost(candidate) else { return }
        appKitWindow = candidate
        // NSWindow.StyleMask.fullScreen
        let mask = candidate.value(forKey: "styleMask") as? UInt ?? 0
        if mask & (1 << 14) == 0 { candidate.perform(NSSelectorFromString("toggleFullScreen:"), with: nil) }
    }

    func isWindow(_ object: Any?) -> Bool {
        guard let appKitWindow else { return false }
        return (object as AnyObject?) === appKitWindow
    }

    private func isHost(_ candidate: NSObject) -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let scene = window?.windowScene else { return false }
        return Self.frame(of: candidate) == scene.effectiveGeometry.systemFrame
        #else
        return false
        #endif
    }

    /// An AppKit window's frame as UIKit gives a scene's: from the top of the main screen, where
    /// AppKit counts from its bottom.
    private static func frame(of appKitWindow: NSObject) -> CGRect? {
        guard let frame = (appKitWindow.value(forKey: "frame") as? NSValue)?.cgRectValue,
              let screens = (NSClassFromString("NSScreen") as? NSObject.Type)?.value(forKey: "screens") as? [NSObject],
              let main = (screens.first?.value(forKey: "frame") as? NSValue)?.cgRectValue else { return nil }
        return CGRect(x: frame.minX, y: main.height - frame.maxY, width: frame.width, height: frame.height)
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
#endif

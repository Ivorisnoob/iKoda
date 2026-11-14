import AppIntents
import KodaCore
import SwiftUI

@main
struct KodaApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// Answers which way the iPhone may turn: upright, except a full-screen video.
    #if os(iOS)
    @UIApplicationDelegateAdaptor(KodaAppDelegate.self) private var appDelegate
    #else
    /// The Dock icon's menu.
    @NSApplicationDelegateAdaptor(KodaMacAppDelegate.self) private var appDelegate
    #endif

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Siri and Shortcuts reach the app's objects through this, also when an intent starts
        // the app in the background.
        AppDependencyManager.shared.add(dependency: model)
        #if os(macOS)
        KodaMacAppDelegate.model = model
        #endif
    }

    var body: some Scene {
        mainWindow
        // The root view's frame sets the smallest window and nothing sets a largest. No
        // `defaultSize`: on Catalyst it pins the scene's maximum size to the default size, so the
        // window could never grow past 1180×820; the first window is the system's own size.
        .windowResizability(.contentMinSize)
        .commands {
            KodaCommands(model: model)
            #if os(macOS)
            InterfaceScaleCommands()
            // View → Show/Hide Sidebar (⌃⌘S), as the Mac's apps have it.
            SidebarCommands()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // The queue and position survive the app being closed from the switcher.
            if phase != .active { model.saveState() }
            if phase == .active {
                model.lastFM.syncSoon()
                model.accountsBecameActive()
            }
        }

        #if os(macOS)
        // Music's Mini Player: the cover and the controls in a small window over other apps.
        // As a Window scene it is listed in the Window menu, where ⌥⌘M opens it.
        Window("Mini Player", id: MacMiniPlayerView.windowID) {
            MacMiniPlayerView()
                .appEnvironment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        // A square in the top corner of the screen's free area, out of the way, as Music's opens.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect
            let side = MacMiniPlayerView.side
            return WindowPlacement(CGPoint(x: screen.maxX - side - 20, y: screen.minY + 20),
                                   size: CGSize(width: side, height: side))
        }
        .keyboardShortcut("m", modifiers: [.command, .option])

        // The Mac's own Settings window: Koda → Settings… (⌘,), panes along its toolbar.
        Settings {
            MacSettingsView()
                .appEnvironment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }

        // Software Update: opened by Koda → Check for Updates… or when a daily check finds one.
        // Not listed in the Window menu, as Sparkle's isn't.
        Window("Software Update", id: SoftwareUpdateView.windowID) {
            SoftwareUpdateView()
                .appEnvironment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .defaultPosition(.center)
        .commandsRemoved()
        // Opened for a reason each time; reopened at launch it would wait on a check never made.
        .restorationBehavior(.disabled)

        // A full-screen video: its own window, keyed by one value so there is only ever one.
        WindowGroup("Video", id: MacVideoWindow.windowID, for: String.self) { _ in
            MacVideoWindow()
                .appEnvironment(model)
        }
        #endif
    }
}

extension KodaApp {
    #if os(macOS)
    /// One window is the whole app on the Mac (a second would play over the first): a Window
    /// scene, which the Window menu lists as Koda and brings back once closed, as Music's is.
    private var mainWindow: some Scene {
        Window("Koda", id: "main") { mainContent }
    }
    #else
    private var mainWindow: some Scene {
        WindowGroup { mainContent }
    }
    #endif

    private var mainContent: some View {
        RootView()
            .appEnvironment(model)
            // Pausing listening history pauses scrobbling with it.
            .onChange(of: model.settings.savesListeningHistory) { _, saves in model.lastFM.isPaused = !saves }
            .preferredColorScheme(model.settings.theme.colorScheme)
            .frame(minWidth: Platform.isMac ? 700 : nil, minHeight: Platform.isMac ? 520 : nil)
            // Spotlight and Siri learn the liked songs and playlists, and again when they change.
            .task(id: IntentsIndexKey(model.library)) { IntentsIndex.update(model) }
    }
}

/// Changes when what Siri and Spotlight are told about does.
private struct IntentsIndexKey: Equatable {
    var liked: [String]
    var playlists: [String]

    @MainActor
    init(_ library: Library) {
        liked = library.liked.map(\.id)
        playlists = library.userPlaylists.map { "\($0.id)\($0.name)\($0.songs.count)" }
    }
}

extension View {
    /// The app's shared objects. Given again to anything presented full screen: the Mac shows a
    /// presented view in its own hosting controller, which doesn't inherit them.
    func appEnvironment(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.player)
            .environment(model.library)
            .environment(model.downloads)
            .environment(model.lastFM)
    }
}

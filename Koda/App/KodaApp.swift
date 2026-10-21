import AppIntents
import KodaCore
import SwiftUI

@main
struct KodaApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Siri and Shortcuts reach the app's objects through this, also when an intent starts
        // the app in the background.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appEnvironment(model)
                // Pausing listening history pauses scrobbling with it.
                .onChange(of: model.settings.savesListeningHistory) { _, saves in model.lastFM.isPaused = !saves }
                .preferredColorScheme(model.settings.theme.colorScheme)
                .frame(minWidth: Platform.isMac ? 700 : nil, minHeight: Platform.isMac ? 520 : nil)
                // Spotlight and Siri learn the liked songs and playlists, and again when they change.
                .task(id: IntentsIndexKey(model.library)) { IntentsIndex.update(model) }
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .commands { KodaCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in
            // The queue and position survive the app being closed from the switcher.
            if phase != .active { model.saveState() }
            if phase == .active {
                model.lastFM.syncSoon()
                // The account's own library, read when it has gone stale.
                Task { await model.account.syncIfNeeded() }
            }
        }

        #if targetEnvironment(macCatalyst)
        // Keyed by one value, so asking again brings the open Settings window forward.
        WindowGroup("Settings", id: MacSettingsView.windowID, for: String.self) { _ in
            MacSettingsView()
                .appEnvironment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .defaultSize(width: 820, height: 600)
        #endif
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
            .environment(model.videoPlayback)
            .environment(model.videoModel)
            .environment(model.library)
            .environment(model.downloads)
            .environment(model.lastFM)
            .environment(model.account)
    }
}

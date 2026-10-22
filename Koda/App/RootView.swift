import KodaCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @State private var homePath: [Route] = []
    @State private var libraryPath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var videosPath: [Route] = []
    @State private var subscriptionsPath: [Route] = []
    @State private var watchedPath: [Route] = []
    @State private var videoSearchPath: [Route] = []
    @Namespace private var playerTransition
    /// Now Playing's presentation, owned here rather than bound to the model: when the cover's
    /// binding comes from an @Observable model, the zoom out of the tab bar accessory finds no
    /// source view and falls back to a plain slide up (FB20772137, iOS 26.1 on). The model's
    /// `isNowPlayingPresented` mirrors it, for opening and closing from elsewhere.
    @State private var showsNowPlaying = false

    var body: some View {
        if Platform.isMac {
            MacRootView()
        } else {
            phone
        }
    }

    private var phone: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            if model.settings.mode == .music {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                    NavigationStack(path: $homePath) {
                        // A fresh Home for each profile: its own mix, picks and snapshot.
                        HomeView().id(model.roster.activeID).routeDestinations()
                    }
                }
                Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView().routeDestinations()
                    }
                }
                Tab(value: AppTab.search, role: .search) {
                    NavigationStack(path: $searchPath) {
                        SearchView().routeDestinations()
                    }
                }
            } else {
                Tab("Home", systemImage: "play.rectangle.fill", value: AppTab.videos) {
                    NavigationStack(path: $videosPath) {
                        // Each profile's own feed and watched list.
                        VideoHomeView(kind: .home).id(model.roster.activeID).routeDestinations()
                    }
                }
                if model.roster.active.isSignedIn {
                    Tab("Subscriptions", systemImage: "person.2.crop.square.stack.fill", value: AppTab.subscriptions) {
                        NavigationStack(path: $subscriptionsPath) {
                            VideoHomeView(kind: .subscriptions).id(model.roster.activeID).routeDestinations()
                        }
                    }
                }
                Tab("Library", systemImage: "rectangle.stack.fill", value: AppTab.watched) {
                    NavigationStack(path: $watchedPath) {
                        VideoLibraryView().routeDestinations()
                    }
                }
                Tab(value: AppTab.videoSearch, role: .search) {
                    NavigationStack(path: $videoSearchPath) {
                        VideoSearchView().routeDestinations()
                    }
                }
            }
        }
        // Each mode opens on its own Home.
        .onChange(of: model.settings.mode) { _, mode in
            if model.selectedTab.mode != mode { model.selectedTab = mode == .music ? .home : .videos }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // iOS 27 made the automatic edge effect hard: an opaque band under the bars. A soft one
        // blurs content progressively instead. It applies to every scroll view below here.
        .scrollEdgeEffectStyle(.soft, for: .all)
        // The songs' player belongs to music mode: in video mode a video is what plays (and
        // starting one paused the songs), so the bar under the tabs is the video's alone.
        .modifier(MiniPlayerAccessory(isEnabled: player.current != nil && model.settings.mode == .music) {
            MiniPlayer { showsNowPlaying = true }
                .matchedTransitionSource(id: "player", in: playerTransition)
        })
        .fullScreenCover(isPresented: $showsNowPlaying) {
            NowPlayingView()
                .appEnvironment(model)
                .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
        }
        .onChange(of: model.isNowPlayingPresented) { _, shown in showsNowPlaying = shown }
        .onChange(of: showsNowPlaying) { _, shown in model.isNowPlayingPresented = shown }
        // Now Playing opens already in the song's colours, rather than fading into them mid-zoom.
        .task(id: player.current?.artwork) { await model.nowPlayingPalette.load(player.current?.artwork) }
        .playlistPicker(whenOnTop: !showsNowPlaying)
        .sheet(isPresented: $model.isProfilePresented) { ProfileView().appEnvironment(model) }
        .sheet(isPresented: $model.isAddingProfile) { AddProfileView().appEnvironment(model) }
        .fullScreenCover(item: $model.onboarding) { start in
            OnboardingView(start: start, music: model.music, library: model.library).appEnvironment(model)
        }
        // Pages opened in another profile (its playlists, its liked songs) aren't this one's.
        .onChange(of: model.roster.activeID) {
            homePath = []
            libraryPath = []
            searchPath = []
            videosPath = []
            subscriptionsPath = []
            watchedPath = []
            videoSearchPath = []
        }
        .onOpenURL { url in
            if !model.open(url) { model.linkError = "Koda can open YouTube Music songs, albums, playlists and artists." }
        }
        .alert("Couldn't Open Link", isPresented: Binding(get: { model.linkError != nil }, set: { if !$0 { model.linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.linkError ?? "")
        }
        .onChange(of: model.pendingRoute) { _, route in
            guard let route else { return }
            model.pendingRoute = nil
            switch model.selectedTab {
            case .home: homePath.append(route)
            case .library: libraryPath.append(route)
            case .videos: videosPath.append(route)
            case .subscriptions: subscriptionsPath.append(route)
            case .watched: watchedPath.append(route)
            case .videoSearch: videoSearchPath.append(route)
            case .search: searchPath.append(route)
            }
        }
    }
}

/// The mini player as the tab bar's accessory; hidden while nothing is queued where the system allows it.
private struct MiniPlayerAccessory<Accessory: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder var accessory: () -> Accessory

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled, content: accessory)
        } else {
            content.tabViewBottomAccessory(content: accessory)
        }
    }
}

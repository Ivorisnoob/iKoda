import KodaCore
import SwiftUI

/// Music or Video: the whole app follows it, as Koda for Android's toggle does.
///
/// iPhone: one glass button at the top of each Home naming the mode, which opens the system menu
/// with both, the way Mail and Photos switch what a screen shows; a segmented control squeezed
/// into the bar beside the profile button read as two cramped buttons. Mac: a segmented control
/// heading the sidebar, as Mac apps head their sidebars.
struct ModeToggle: View {
    @Environment(AppModel.self) private var app

    private var mode: Binding<AppSettings.Mode> {
        Binding(get: { app.settings.mode }, set: { mode in
            withAnimation(.smooth) { app.settings.mode = mode }
        })
    }

    var body: some View {
        Group {
            if Platform.isMac {
                Picker("Mode", selection: mode) {
                    ForEach(AppSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } else {
                Menu {
                    Picker("Mode", selection: mode) {
                        ForEach(AppSettings.Mode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: app.settings.mode.systemImage)
                            .contentTransition(.symbolEffect(.replace))
                        Text(app.settings.mode.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel("Mode")
                .accessibilityValue(app.settings.mode.title)
                .accessibilityHint("Switches between music and videos")
            }
        }
        .sensoryFeedback(.selection, trigger: app.settings.mode)
    }
}

/// Video mode's Search tab: YouTube's results, channels first.
struct VideoSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var search = VideoSearchModel()

    var body: some View {
        @Bindable var search = search
        ScrollView {
            if search.submitted != nil {
                VideoSearchResultsView(model: search)
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    ExploreGrid()
                    if !library.watched.isEmpty {
                        RecentlyWatchedShelf(videos: Array(library.watched.prefix(12)))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, prompt: "Videos and channels")
        .onSubmit(of: .search) { Task { await search.search(search.query, music: app.music) } }
        .onChange(of: search.query) { _, text in if text.isEmpty { search.clear() } }
    }
}

/// Video mode's Library: Watch Later, Liked Videos and the channels followed (signed in), then
/// what was watched, most recent first, to go back to or remove.
struct VideoLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var confirmsClear = false

    private var signedIn: Bool { !Platform.isMac && app.roster.active.isSignedIn && !app.roster.active.isExpired }

    var body: some View {
        Group {
            if Platform.isMac {
                MacPage {
                    MacPageTitle(title: "Watched") {
                        if !library.watched.isEmpty {
                            Button("Clear…") { confirmsClear = true }
                        }
                    }
                    if library.watched.isEmpty {
                        empty.frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        VideoCardGrid(videos: library.watched) { library.removeWatched($0.id) }
                    }
                }
            } else {
                List {
                    if signedIn {
                        Section {
                            NavigationLink(value: Route.videoPlaylist(id: "WL", title: "Watch Later")) {
                                Label("Watch Later", systemImage: "clock")
                            }
                            NavigationLink(value: Route.videoPlaylist(id: "LL", title: "Liked Videos")) {
                                Label("Liked Videos", systemImage: "hand.thumbsup")
                            }
                            NavigationLink(value: Route.subscribedChannels) {
                                Label("Channels", systemImage: "person.2")
                            }
                        }
                        .font(.body.weight(.medium))
                    }
                    Section {
                    ForEach(library.watched) { video in
                        NavigationLink(value: Route.video(video)) { VideoRow(video: video) }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    withAnimation { library.removeWatched(video.id) }
                                }
                            }
                    }
                    } header: {
                        if signedIn, !library.watched.isEmpty { Text("History") }
                    }
                }
                .listStyle(.plain)
                .overlay { if library.watched.isEmpty, !signedIn { empty } }
                .toolbar {
                    if !library.watched.isEmpty {
                        Button("Clear", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .navigationTitle(Platform.isMac ? "Watched" : "Library")
        .confirmationDialog("Clear what you've watched?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Watched", role: .destructive) {
                for video in library.watched { library.removeWatched(video.id) }
            }
        } message: {
            Text("Videos you've watched are removed from this list and no longer shape the Home feed.")
        }
    }

    private var empty: some View {
        ContentUnavailableView("Nothing Watched Yet", systemImage: "play.rectangle",
                               description: Text("Videos you watch appear here."))
    }
}

/// The topics to browse before searching: a grid of glass tiles.
private struct ExploreGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explore").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ExploreTopic.allCases) { topic in
                    NavigationLink(value: Route.explore(topic)) {
                        Label(topic.title, systemImage: topic.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 14)
                            .background(.fill.quinary, in: .rect(cornerRadius: 14, style: .continuous))
                            .contentShape(.rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, VideoMetrics.side)
    }
}

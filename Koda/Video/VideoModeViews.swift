import KodaCore
import SwiftUI

/// Music or Video, at the top of Home (iPhone) and of the sidebar (Mac): the whole app follows it,
/// as Koda for Android's toggle does.
struct ModeToggle: View {
    @Environment(AppModel.self) private var app
    @State private var flips = 0

    var body: some View {
        Picker("Mode", selection: Binding(get: { app.settings.mode }, set: { mode in
            flips += 1
            withAnimation(.smooth) { app.settings.mode = mode }
        })) {
            ForEach(AppSettings.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .sensoryFeedback(.selection, trigger: flips)
        .accessibilityLabel("Mode")
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
            } else if !library.watched.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    RecentlyWatchedShelf(videos: Array(library.watched.prefix(12)))
                }
                .padding(.vertical, 8)
            }
        }
        .overlay {
            if search.submitted == nil, library.watched.isEmpty {
                ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass",
                                       description: Text("Find videos and channels."))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, prompt: "Videos and channels")
        .onSubmit(of: .search) { Task { await search.search(search.query, music: app.music) } }
        .onChange(of: search.query) { _, text in if text.isEmpty { search.clear() } }
    }
}

/// Video mode's Library: what was watched, most recent first, to go back to or remove.
struct VideoLibraryView: View {
    @Environment(Library.self) private var library
    @State private var confirmsClear = false

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
                    ForEach(library.watched) { video in
                        NavigationLink(value: Route.video(video)) { VideoRow(video: video) }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    withAnimation { library.removeWatched(video.id) }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .overlay { if library.watched.isEmpty { empty } }
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

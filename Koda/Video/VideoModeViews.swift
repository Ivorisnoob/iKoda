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

import KodaCore
import SwiftUI

/// Video mode's Home (the profile's feed: just the feed, as YouTube's is; what was watched is in
/// Library, and the Search tab offers it before a search) or Subscriptions. The
/// iPhone shows full-width cards; the Mac a grid. Search is a tab (iPhone) or the toolbar (Mac).
struct VideoHomeView: View {
    /// Kept by the app per profile (`AppModel.videoFeed`), so it outlives this view.
    let feed: VideoFeedModel
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var filter: VideoFeedFilter = .all

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    private var signedIn: Bool { app.roster.active.isSignedIn && !app.roster.active.isExpired }

    // MARK: iPhone

    /// Videos left part-way, most recent first, as YouTube's own row: where each would pick up.
    private var continueWatching: [Video] {
        Array(library.watched.filter { library.videoProgress[$0.id]?.resumeAt != nil }.prefix(12))
    }

    private var phoneBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if feed.kind == .home, !continueWatching.isEmpty {
                    ContinueWatchingShelf(videos: continueWatching)
                }
                feedList(feed)
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(feed.kind == .subscriptions ? "Subscriptions" : "Videos")
        .refreshable { await load(feed) }
        .task { if feed.needsLoad { await load(feed) } }
        #if os(iOS)
        .toolbar {
            if feed.kind == .home, app.settings.videoModeEnabled {
                ToolbarItem(placement: .topBarLeading) { ModeToggle() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
        #endif
    }

    @ViewBuilder
    private func feedList(_ model: VideoFeedModel) -> some View {
        switch model.state {
        case .loading:
            ForEach(Video.placeholders) { VideoCard(video: $0).padding(.horizontal, VideoMetrics.side) }
                .loadingPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Videos", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load(model) } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        case .loaded(let videos):
            if videos.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "play.rectangle",
                                       description: Text(model.kind == .subscriptions ? "Videos from channels you subscribe to appear here." : "Search for something to watch."))
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                ForEach(videos) { video in
                    NavigationLink(value: Route.video(video)) {
                        VideoCard(video: video, width: 420)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { VideoMenuItems(video: video) }
                    .padding(.horizontal, VideoMetrics.side)
                }
                if model.canLoadMore {
                    LoadMoreTrigger { await model.loadMore(music: app.music, library: library) }
                }
            }
        }
    }

    // MARK: Mac

    private var macBody: some View {
        MacPage {
            MacPageTitle(title: feed.kind == .subscriptions ? "Subscriptions" : "Videos") {
                HStack(spacing: 12) {
                    Picker("Show", selection: $filter) {
                        ForEach(VideoFeedFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    // Refreshing keeps the feed on screen; the button turns into the spinner.
                    ZStack {
                        if feed.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(feed) } }
                                .labelStyle(.iconOnly)
                                .help("Refresh (⌘R)")
                        }
                    }
                    .frame(width: 28)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            if feed.kind == .home, filter == .all, !continueWatching.isEmpty {
                ContinueWatchingShelf(videos: continueWatching)
            }
            VideoGrid(model: feed, filter: filter) { await load(feed) }
        }
        .navigationTitle(feed.kind == .subscriptions ? "Subscriptions" : "Videos")
        .task { if feed.needsLoad { await load(feed) } }
    }

    private func load(_ model: VideoFeedModel) async {
        await app.accountWork?.value
        await model.load(music: app.music, library: library, signedIn: signedIn)
    }
}

/// A feed as the Mac's grid of cards, paging as its end comes into view.
struct VideoGrid: View {
    let model: VideoFeedModel
    var filter: VideoFeedFilter = .all
    let retry: () async -> Void
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        switch model.state {
        case .loading:
            VideoCardGrid(videos: Video.placeholders).loadingPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Videos", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let videos):
            if videos.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "play.rectangle",
                                       description: Text(model.kind == .subscriptions ? "Videos from channels you subscribe to appear here." : "Search YouTube from the toolbar."))
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                let shown = videos.filter { filter.includes($0, library: library) }
                if shown.isEmpty, !model.canLoadMore {
                    ContentUnavailableView("No \(filter.title) Videos", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Nothing in this feed matches. Choose All to see everything."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                VideoCardGrid(videos: shown)
                    .animation(.smooth, value: filter)
                if model.canLoadMore {
                    LoadMoreTrigger { await model.loadMore(music: app.music, library: library) }
                }
            }
        }
    }
}

/// Cards in columns that fit the window, each opening its watch page.
struct VideoCardGrid: View {
    let videos: [Video]
    var showsChannel = true
    /// A context menu item that takes the video off this list (Watched).
    var remove: ((Video) -> Void)?
    @State private var width: CGFloat = 0

    /// Cards fill the row, as many as are nearest a card 300 points wide at the Interface Size.
    /// Rounded rather than as many as fit: a zoom step then changes the count (and the cards'
    /// size) much sooner, where filling the row kept wide windows looking the same.
    private var columns: Int {
        guard Platform.isMac else { return 1 }
        let spacing = CGFloat(20).scaled
        return max(1, Int(((width + spacing) / (CGFloat(300).scaled + spacing)).rounded()))
    }

    var body: some View {
        let spacing = CGFloat(20).scaled
        let cardWidth = width > 0 ? (width - spacing * CGFloat(columns - 1)) / CGFloat(columns) : 400
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
                  spacing: CGFloat(28).scaled) {
            ForEach(videos) { video in
                NavigationLink(value: Route.video(video)) {
                    VideoCard(video: video, width: cardWidth, showsChannel: showsChannel)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    VideoMenuItems(video: video)
                    if let remove {
                        Button("Remove from Watched", systemImage: "trash", role: .destructive) { remove(video) }
                    }
                }
            }
        }
        // Measured on the flexible frame, never on the cards it then sizes.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, VideoMetrics.side)
    }
}

/// What a feed shows: everything, or only some of it, worked out from what's loaded (YouTube's
/// own chips change with every feed; these mean the same thing each time).
enum VideoFeedFilter: String, CaseIterable, Identifiable {
    case all, unwatched, short, long, live

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .unwatched: "Not Watched"
        case .short: "Under 4 Minutes"
        case .long: "Over 20 Minutes"
        case .live: "Live"
        }
    }

    @MainActor
    func includes(_ video: Video, library: Library) -> Bool {
        switch self {
        case .all: true
        case .unwatched: library.videoProgress[video.id] == nil && !library.watched.contains { $0.id == video.id }
        case .short: !video.isLive && (video.duration ?? .infinity) < 240
        case .long: !video.isLive && (video.duration ?? 0) > 1200
        case .live: video.isLive
        }
    }
}

/// Video pages' side margin: the iPhone's shelves' 20 points, the Mac's page gutter.
enum VideoMetrics {
    static var side: CGFloat { Platform.isMac ? MacMetrics.gutter : 20 }
}

extension Video {
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// What was watched lately, to go back to: the app's own shelf on each platform.
struct RecentlyWatchedShelf: View {
    let videos: [Video]

    var body: some View {
        if Platform.isMac {
            MacShelf(title: "Recently Watched", seeAll: .watched) { cards(width: 260) }
        } else {
            ShelfView(title: "Recently Watched", seeAll: .watched) { cards(width: 220) }
        }
    }

    private func cards(width: CGFloat) -> some View {
        ForEach(videos) { video in
            NavigationLink(value: Route.video(video)) {
                VideoCard(video: video, width: width, showsChannel: false)
                    .frame(width: width)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Videos left part-way, at the top of Home: each card shows how far it got, and opens where it
/// was left.
struct ContinueWatchingShelf: View {
    let videos: [Video]

    var body: some View {
        if Platform.isMac {
            MacShelf(title: "Continue Watching", seeAll: .watched) { cards(width: CGFloat(280).scaled) }
        } else {
            ShelfView(title: "Continue Watching", seeAll: .watched) { cards(width: 240) }
        }
    }

    private func cards(width: CGFloat) -> some View {
        ForEach(videos) { video in
            NavigationLink(value: Route.video(video)) {
                VideoCard(video: video, width: width)
                    .frame(width: width)
            }
            .buttonStyle(.plain)
            .contextMenu { VideoMenuItems(video: video) }
        }
    }
}

/// Search results: matching channels in a row, then videos.
struct VideoSearchResultsView: View {
    let model: VideoSearchModel
    @Environment(AppModel.self) private var app

    var body: some View {
        switch model.state {
        case .loading, nil:
            content(VideoSearchResults(channels: [], videos: VideoPage(videos: Video.placeholders)))
                .loadingPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                if let query = model.submitted {
                    Button("Try Again") { Task { await model.search(query, music: app.music) } }.buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let results):
            if results.videos.videos.isEmpty, results.channels.isEmpty {
                // The filters stay, so ones that left nothing can be changed or cleared.
                VStack(alignment: .leading, spacing: 24) {
                    SearchFilterBar(model: model)
                    ContentUnavailableView.search(text: model.submitted ?? "")
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                .padding(.vertical, 8)
            } else {
                content(results)
            }
        }
    }

    private func content(_ results: VideoSearchResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            SearchFilterBar(model: model)
            if !results.channels.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(results.channels) { channel in
                            NavigationLink(value: Route.channel(id: channel.id, name: channel.name)) {
                                ChannelCell(channel: channel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentMargins(.horizontal, VideoMetrics.side, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
            if Platform.isMac {
                VideoCardGrid(videos: results.videos.videos)
            } else {
                ForEach(results.videos.videos) { video in
                    NavigationLink(value: Route.video(video)) { VideoCard(video: video, width: 420) }
                        .buttonStyle(.plain)
                        .contextMenu { VideoMenuItems(video: video) }
                        .padding(.horizontal, VideoMetrics.side)
                }
            }
            if results.videos.continuation != nil {
                LoadMoreTrigger { await model.loadMore(music: app.music) }
            }
        }
        .padding(.vertical, 8)
    }
}

/// YouTube's search filters as a row of menus, each showing what it's set to.
private struct SearchFilterBar: View {
    let model: VideoSearchModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                menu("Upload Date", value: \.uploadDate, options: VideoSearchFilters.UploadDate.allCases, any: "Any Time", title: Self.title)
                menu("Length", value: \.length, options: [.underFourMinutes, .fourToTwentyMinutes, .overTwentyMinutes], any: "Any Length", title: Self.title)
                menu("Type", value: \.type, options: VideoSearchFilters.ResultType.allCases, any: "All Results", title: Self.title)
                Picker("Sort By", selection: binding(\.sort)) {
                    Text("Relevance").tag(VideoSearchFilters.Sort.relevance)
                    Text("View Count").tag(VideoSearchFilters.Sort.viewCount)
                }
                .pickerStyle(.menu)
                .fixedSize()
                if !model.filters.isEmpty {
                    Button("Clear Filters") { refine(VideoSearchFilters()) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, VideoMetrics.side)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func menu<Value: Hashable>(_ label: String, value: WritableKeyPath<VideoSearchFilters, Value?>, options: [Value],
                                       any: String, title: @escaping (Value) -> String) -> some View {
        Picker(label, selection: binding(value)) {
            Text(any).tag(Value?.none)
            Divider()
            ForEach(options, id: \.self) { Text(title($0)).tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func binding<Value>(_ key: WritableKeyPath<VideoSearchFilters, Value>) -> Binding<Value> {
        Binding(get: { model.filters[keyPath: key] }, set: { value in
            var filters = model.filters
            filters[keyPath: key] = value
            refine(filters)
        })
    }

    private func refine(_ filters: VideoSearchFilters) {
        Task { await model.refine(filters, music: app.music) }
    }

    static func title(_ date: VideoSearchFilters.UploadDate) -> String {
        switch date {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .thisYear: "This Year"
        }
    }

    static func title(_ length: VideoSearchFilters.Length) -> String {
        switch length {
        case .underFourMinutes: "Under 4 Minutes"
        case .fourToTwentyMinutes: "4–20 Minutes"
        case .overTwentyMinutes: "Over 20 Minutes"
        }
    }

    static func title(_ type: VideoSearchFilters.ResultType) -> String {
        switch type {
        case .videos: "Videos"
        case .channels: "Channels"
        }
    }
}

private struct ChannelCell: View {
    let channel: ChannelSummary

    var body: some View {
        VStack(spacing: 6) {
            ChannelAvatar(avatar: channel.avatar, size: 72)
            Text(channel.name)
                .font(.scaled(.subheadline).weight(.medium))
                .lineLimit(1)
            if let subscribers = channel.subscribers {
                Text(subscribers.replacingOccurrences(of: " subscribers", with: ""))
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 96)
        .accessibilityElement(children: .combine)
    }
}

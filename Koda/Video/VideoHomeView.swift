import KodaCore
import SwiftUI

/// Video mode's Home (the profile's feed, and what was watched lately) or Subscriptions. The
/// iPhone shows full-width cards; the Mac a grid. Search is a tab (iPhone) or the toolbar (Mac).
struct VideoHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var feed: VideoFeedModel

    init(kind: VideoFeedModel.Kind = .home) {
        _feed = State(initialValue: VideoFeedModel(kind: kind))
    }

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    private var signedIn: Bool { app.roster.active.isSignedIn && !app.roster.active.isExpired }

    // MARK: iPhone

    private var phoneBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if feed.kind == .home, !library.watched.isEmpty {
                    RecentlyWatchedShelf(videos: Array(library.watched.prefix(12)))
                }
                feedList(feed)
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(feed.kind == .subscriptions ? "Subscriptions" : "Videos")
        .refreshable { await load(feed) }
        .task { if feed.state.value == nil { await load(feed) } }
        .toolbar {
            if feed.kind == .home {
                ToolbarItem(placement: .topBarLeading) { ModeToggle() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
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
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await model.loadMore(music: app.music, library: library) }
                }
            }
        }
    }

    // MARK: Mac

    private var macBody: some View {
        MacPage {
            MacPageTitle(title: feed.kind == .subscriptions ? "Subscriptions" : "Videos") {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(feed) } }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if feed.kind == .home, !library.watched.isEmpty {
                RecentlyWatchedShelf(videos: Array(library.watched.prefix(12)))
            }
            VideoGrid(model: feed) { await load(feed) }
        }
        .navigationTitle(feed.kind == .subscriptions ? "Subscriptions" : "Videos")
        .task { if feed.state.value == nil { await load(feed) } }
    }

    private func load(_ model: VideoFeedModel) async {
        await app.accountWork?.value
        await model.load(music: app.music, library: library, signedIn: signedIn)
    }
}

/// A feed as the Mac's grid of cards, paging as its end comes into view.
struct VideoGrid: View {
    let model: VideoFeedModel
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
                VideoCardGrid(videos: videos)
                if model.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await model.loadMore(music: app.music, library: library) }
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

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 20, alignment: .top)], spacing: 28) {
            ForEach(videos) { video in
                NavigationLink(value: Route.video(video)) {
                    VideoCard(video: video, width: 360, showsChannel: showsChannel)
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
        .padding(.horizontal, VideoMetrics.side)
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
                ContentUnavailableView.search(text: model.submitted ?? "")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                content(results)
            }
        }
    }

    private func content(_ results: VideoSearchResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
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
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await model.loadMore(music: app.music) }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ChannelCell: View {
    let channel: ChannelSummary

    var body: some View {
        VStack(spacing: 6) {
            ChannelAvatar(avatar: channel.avatar, size: 72)
            Text(channel.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subscribers = channel.subscribers {
                Text(subscribers.replacingOccurrences(of: " subscribers", with: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 96)
        .accessibilityElement(children: .combine)
    }
}

import KodaCore
import SwiftUI

/// The topics YouTube keeps a page of shelves for, offered to everyone, signed in or not:
/// Explore in the Mac's sidebar, and in the iPhone's video Search before a search.
enum ExploreTopic: String, CaseIterable, Identifiable, Hashable {
    case music, live, news, sports, learning

    var id: Self { self }

    var title: String {
        switch self {
        case .music: "Music"
        case .live: "Live"
        case .news: "News"
        case .sports: "Sports"
        case .learning: "Learning"
        }
    }

    var systemImage: String {
        switch self {
        case .music: "music.note"
        case .live: "dot.radiowaves.left.and.right"
        case .news: "newspaper"
        case .sports: "sportscourt"
        case .learning: "lightbulb"
        }
    }

    /// The topic's channel [verified October 2026]. Gaming's page has a single short shelf, so
    /// it isn't offered.
    var browseId: String {
        switch self {
        case .music: "UC-9-kyTW8ZkZNDHQJ6FgpwQ"
        case .live: "UC4R8DWoMoI7CAwX8_LjQHig"
        case .news: "UCYfdidRxbB8Qhf0Nx7ioOYw"
        case .sports: "UCEgdi0XIXXZ-qJOFPf4JSKw"
        case .learning: "UCtFRv9O2AHqOZjjynzrv-xg"
        }
    }
}

/// A topic's shelves of videos, each a row that scrolls sideways.
struct ExploreView: View {
    let topic: ExploreTopic
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[VideoShelf]> = .loading

    private static let placeholder = (0..<3).map { _ in VideoShelf(title: "A shelf of videos", videos: Array(Video.placeholders.prefix(4))) }

    var body: some View {
        Group {
            if Platform.isMac {
                MacPage {
                    MacPageTitle(title: topic.title, subtitle: "Explore")
                    content
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) { content }
                        .padding(.vertical, 8)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(topic.title)
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            shelves(Self.placeholder).loadingPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load \(topic.title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let loaded):
            shelves(loaded)
        }
    }

    @ViewBuilder
    private func shelves(_ shelves: [VideoShelf]) -> some View {
        ForEach(shelves) { shelf in
            if Platform.isMac {
                MacShelf(title: shelf.title) { cards(shelf.videos, width: 280) }
            } else {
                ShelfView(title: shelf.title) { cards(shelf.videos, width: 260) }
            }
        }
    }

    private func cards(_ videos: [Video], width: CGFloat) -> some View {
        ForEach(videos) { video in
            NavigationLink(value: Route.video(video)) {
                VideoCard(video: video, width: width).frame(width: width)
            }
            .buttonStyle(.plain)
            .contextMenu { VideoMenuItems(video: video) }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await app.music.explore(topic.browseId))
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }
}

/// A playlist of videos: Watch Later and Liked Videos, the account's own.
struct VideoPlaylistView: View {
    let playlistId: String
    let title: String
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<VideoPage> = .loading
    @State private var isLoadingMore = false

    private var systemImage: String { playlistId == "WL" ? "clock" : "hand.thumbsup" }

    var body: some View {
        Group {
            if Platform.isMac {
                MacPage {
                    MacPageTitle(title: title) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                            .labelStyle(.iconOnly)
                            .keyboardShortcut("r", modifiers: .command)
                    }
                    content
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) { content }
                        .padding(.vertical, 8)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            list(Video.placeholders).loadingPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load \(title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let page) where page.videos.isEmpty:
            ContentUnavailableView(playlistId == "WL" ? "Nothing Saved for Later" : "No Liked Videos", systemImage: systemImage,
                                   description: Text(playlistId == "WL" ? "Videos you save to Watch Later on YouTube appear here."
                                                     : "Videos you like appear here."))
                .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let page):
            list(page.videos)
            if page.continuation != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
            }
        }
    }

    @ViewBuilder
    private func list(_ videos: [Video]) -> some View {
        if Platform.isMac {
            VideoCardGrid(videos: videos)
        } else {
            ForEach(videos) { video in
                NavigationLink(value: Route.video(video)) { VideoRow(video: video) }
                    .buttonStyle(.plain)
                    .contextMenu { VideoMenuItems(video: video) }
                    .padding(.horizontal, VideoMetrics.side)
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await app.music.videoPlaylist(playlistId).videos)
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, var page = state.value, let token = page.continuation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let more = try? await app.music.moreVideos(token, from: .browse) else { return }
        let known = Set(page.videos.map(\.id))
        page.videos += more.videos.filter { !known.contains($0.id) }
        page.continuation = more.continuation
        state = .loaded(page)
    }
}

/// Every channel the account subscribes to, as YouTube's sidebar lists them.
struct SubscribedChannelsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let channels = app.subscribedChannels, !channels.isEmpty {
                if Platform.isMac {
                    MacPage {
                        MacPageTitle(title: "Channels")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 20, alignment: .top)], spacing: 24) {
                            ForEach(channels, id: \.id) { channel in cell(channel) }
                        }
                        .padding(.horizontal, VideoMetrics.side)
                    }
                } else {
                    List(channels, id: \.id) { channel in
                        if let id = channel.id {
                            NavigationLink(value: Route.channel(id: id, name: channel.name)) {
                                HStack(spacing: 12) {
                                    ChannelAvatar(avatar: channel.avatar, size: 40)
                                    Text(channel.name).font(.body.weight(.medium))
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await app.loadSubscribedChannels() }
                }
            } else if app.subscribedChannels == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Subscriptions", systemImage: "person.2",
                                       description: Text("Channels you subscribe to appear here."))
            }
        }
        .navigationTitle("Channels")
        .task { if app.subscribedChannels == nil { await app.loadSubscribedChannels() } }
    }

    @ViewBuilder
    private func cell(_ channel: ChannelRef) -> some View {
        if let id = channel.id {
            NavigationLink(value: Route.channel(id: id, name: channel.name)) {
                VStack(spacing: 8) {
                    ChannelAvatar(avatar: channel.avatar, size: 96)
                    Text(channel.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

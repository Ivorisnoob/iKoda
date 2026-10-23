import KodaCore
import SwiftUI

/// A list of videos that loads a page at a time as it's scrolled.
@MainActor
@Observable
final class VideoFeedModel {
    enum Kind: Hashable {
        /// The account's Home, or signed out one Koda builds: Up Next of what was watched, then
        /// searches for the artists picked in taste setup, then popular videos.
        case home
        case subscriptions
    }

    let kind: Kind
    private(set) var state: LoadState<[Video]> = .loading
    private(set) var isLoadingMore = false
    @ObservationIgnored private var continuation: String?
    /// Signed out, Home pages through the watched list six seeds at a time.
    @ObservationIgnored private var seedOffset = 0
    @ObservationIgnored private var signedInFeed = false

    init(kind: Kind) {
        self.kind = kind
    }

    var videos: [Video] { state.value ?? [] }

    func load(music: YouTubeMusic, library: Library, signedIn: Bool) async {
        if state.value == nil { state = .loading }
        continuation = nil
        seedOffset = 0
        do {
            switch kind {
            case .subscriptions:
                let page = try await music.videoSubscriptions()
                continuation = page.continuation
                state = .loaded(page.videos)
            case .home:
                if signedIn, let page = try? await music.videoHome(), !page.videos.isEmpty {
                    signedInFeed = true
                    continuation = page.continuation
                    state = .loaded(page.videos)
                    return
                }
                signedInFeed = false
                let built = await builtHome(music: music, library: library)
                if built.isEmpty, state.value == nil { throw MusicError.network }
                state = .loaded(built)
            }
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }

    /// The next page, when the end of the list comes into view.
    func loadMore(music: YouTubeMusic, library: Library) async {
        guard !isLoadingMore, let current = state.value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var more: [Video] = []
        if let token = continuation {
            let page = try? await music.moreVideos(token, from: .browse)
            continuation = page?.continuation
            more = page?.videos ?? []
        } else if kind == .home, !signedInFeed {
            seedOffset += 6
            more = await relatedToWatched(music: music, library: library)
        }
        let known = Set(current.map(\.id))
        let fresh = more.filter { !known.contains($0.id) }
        if !fresh.isEmpty { state = .loaded(current + fresh) }
    }

    var canLoadMore: Bool { continuation != nil || (kind == .home && !signedInFeed) }

    private func builtHome(music: YouTubeMusic, library: Library) async -> [Video] {
        let related = await relatedToWatched(music: music, library: library)
        if !related.isEmpty { return related }
        // Nothing watched yet: the artists picked in taste setup, else what's popular.
        let queries = library.taste.artists.prefix(4).map(\.name)
        let lists = await withTaskGroup(of: (Int, [Video]).self) { group in
            for (index, query) in (queries.isEmpty ? ["popular videos this week"] : queries).enumerated() {
                group.addTask { (index, (try? await music.searchVideos(query).videos.videos) ?? []) }
            }
            var byIndex: [Int: [Video]] = [:]
            for await (index, videos) in group { byIndex[index] = videos }
            return byIndex.keys.sorted().map { byIndex[$0]! }
        }
        return Self.unique(TasteModel.interleave(lists))
    }

    /// Up Next of six watched videos, taken in turn, minus what's been watched.
    private func relatedToWatched(music: YouTubeMusic, library: Library) async -> [Video] {
        let watched = library.watched
        let seeds = Array(watched.dropFirst(seedOffset).prefix(6))
        guard !seeds.isEmpty else { return [] }
        let lists = await withTaskGroup(of: (Int, [Video]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { (index, (try? await music.watchPage(seed.id).related.videos) ?? []) }
            }
            var byIndex: [Int: [Video]] = [:]
            for await (index, videos) in group { byIndex[index] = videos }
            return seeds.indices.map { byIndex[$0] ?? [] }
        }
        let seen = Set(watched.map(\.id))
        return Self.unique(TasteModel.interleave(lists)).filter { !seen.contains($0.id) }
    }

    static func unique(_ videos: [Video]) -> [Video] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.id).inserted }
    }
}

@MainActor
@Observable
final class VideoSearchModel {
    var query = ""
    private(set) var submitted: String?
    private(set) var state: LoadState<VideoSearchResults>?
    private(set) var isLoadingMore = false

    func search(_ text: String, music: YouTubeMusic) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return clear() }
        submitted = trimmed
        state = .loading
        do {
            let results = try await music.searchVideos(trimmed)
            guard submitted == trimmed else { return }
            state = .loaded(results)
        } catch {
            guard submitted == trimmed else { return }
            state = .failed(error.friendlyMessage)
        }
    }

    func loadMore(music: YouTubeMusic) async {
        guard !isLoadingMore, var results = state?.value, let token = results.videos.continuation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await music.moreVideos(token, from: .search) else { return }
        let known = Set(results.videos.videos.map(\.id))
        results.videos.videos += page.videos.filter { !known.contains($0.id) }
        results.videos.continuation = page.continuation
        state = .loaded(results)
    }

    func clear() {
        submitted = nil
        state = nil
    }
}

/// What the watch page shows under the player, and more of Up Next as it's scrolled.
@MainActor
@Observable
final class WatchModel {
    let videoId: String
    private(set) var state: LoadState<WatchPage> = .loading
    private(set) var isLoadingMore = false

    init(videoId: String) {
        self.videoId = videoId
    }

    func load(music: YouTubeMusic) async {
        do {
            state = .loaded(try await music.watchPage(videoId))
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }

    func loadMore(music: YouTubeMusic) async {
        guard !isLoadingMore, var page = state.value, let token = page.related.continuation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let more = try? await music.moreVideos(token, from: .next) else { return }
        let known = Set(page.related.videos.map(\.id) + [videoId])
        page.related.videos += more.videos.filter { !known.contains($0.id) }
        page.related.continuation = more.continuation
        state = .loaded(page)
    }
}

/// A channel: its header, the open tab (Videos or Live) in the chosen order, and its About panel.
@MainActor
@Observable
final class ChannelModel {
    let channelId: String
    private(set) var state: LoadState<ChannelPage> = .loading
    private(set) var isLoadingMore = false
    /// A tab or an order being loaded: the list dims rather than emptying.
    private(set) var isSwitching = false
    private(set) var about: LoadState<ChannelAbout>?

    init(channelId: String) {
        self.channelId = channelId
    }

    func load(music: YouTubeMusic) async {
        do {
            state = .loaded(try await music.channel(channelId, tab: state.value.flatMap { page in page.tabs.first { $0.kind == page.tab } }))
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }

    /// Another tab, keeping the header.
    func open(_ tab: ChannelTab, music: YouTubeMusic) async {
        guard var page = state.value, page.tab != tab.kind, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        guard let loaded = try? await music.channel(channelId, tab: tab) else { return }
        page.tab = loaded.tab
        page.sorts = loaded.sorts
        page.videos = loaded.videos
        state = .loaded(page)
    }

    /// The open tab in another order.
    func sort(by sort: ChannelSort, music: YouTubeMusic) async {
        guard var page = state.value, !sort.isSelected, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        guard let sorted = try? await music.channelVideos(sortedBy: sort, channel: page.channel.ref) else { return }
        page.videos = sorted.videos
        // The reload sends the chips again with this one chosen; if not, mark it here.
        page.sorts = sorted.sorts.isEmpty ? page.sorts.map { var s = $0; s.isSelected = $0.id == sort.id; return s } : sorted.sorts
        state = .loaded(page)
    }

    func loadAbout(music: YouTubeMusic) async {
        guard about?.value == nil, let token = state.value?.aboutToken else { return }
        about = .loading
        do {
            about = .loaded(try await music.channelAbout(token))
        } catch {
            about = .failed(error.friendlyMessage)
        }
    }

    func loadMore(music: YouTubeMusic) async {
        guard !isLoadingMore, !isSwitching, var page = state.value, let token = page.videos.continuation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let more = try? await music.moreVideos(token, from: .browse) else { return }
        let known = Set(page.videos.videos.map(\.id))
        let ref = page.channel.ref
        page.videos.videos += more.videos.filter { !known.contains($0.id) }.map { video in
            var video = video
            if video.channel == nil { video.channel = ref }
            return video
        }
        page.videos.continuation = more.continuation
        state = .loaded(page)
    }
}

/// A video's comments, a page at a time.
@MainActor
@Observable
final class CommentsModel {
    private(set) var state: LoadState<[VideoComment]> = .loading
    private(set) var isLoadingMore = false
    @ObservationIgnored private var first: String
    @ObservationIgnored private var continuation: String?

    init(token: String) {
        first = token
    }

    var canLoadMore: Bool { continuation != nil }

    func load(music: YouTubeMusic) async {
        do {
            let page = try await music.comments(first)
            continuation = page.continuation
            state = .loaded(page.comments)
        } catch {
            if state.value == nil { state = .failed(error.friendlyMessage) }
        }
    }

    func loadMore(music: YouTubeMusic) async {
        guard !isLoadingMore, let token = continuation, let current = state.value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await music.comments(token) else { return }
        continuation = page.continuation
        let known = Set(current.map(\.id))
        state = .loaded(current + page.comments.filter { !known.contains($0.id) })
    }
}

import KodaCore
import SwiftUI

/// The pages' state for Video mode: the feed, a search, a playlist and a watch
/// page, each with its `LoadState`. Loads, retries and clears on pull to refresh.
@MainActor
@Observable
final class VideoModel {
    let videos: YouTubeVideos

    private(set) var feed: LoadState<VideoFeed> = .loading
    private(set) var isLoadingMoreFeed = false

    var query = ""
    var submitted: String?
    var filter: VideoSearchFilter = .all
    private(set) var searchResults: LoadState<VideoSearchResults>?
    private(set) var isLoadingMoreSearch = false
    private(set) var playlist: LoadState<VideoPlaylistPage> = .loading
    private(set) var isLoadingMorePlaylist = false
    private(set) var watch: LoadState<VideoWatchPage> = .loading
    init(videos: YouTubeVideos) {
        self.videos = videos
    }

    // MARK: - Feed

    func loadFeed() async {
        feed = .loading
        do {
            let found = try await videos.home()
            feed = .loaded(found)
        } catch {
            feed = .failed(error.friendlyMessage)
        }
    }

    func loadMoreFeed() async {
        guard !isLoadingMoreFeed, let current = feed.value, let token = current.continuation else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        do {
            let (shelves, continuation) = try await videos.feedMore(token)
            guard let feed = feed.value else { return }
            self.feed = .loaded(VideoFeed(shelves: feed.shelves + shelves, continuation: continuation))
        } catch { }
    }

    // MARK: - Search

    func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        submitted = trimmed
        await runSearch()
    }

    func runSearch() async {
        guard let submitted else { return }
        let filter = filter
        searchResults = .loading
        do {
            let found = try await videos.search(submitted, filter: filter)
            guard self.submitted == submitted, self.filter == filter else { return }
            searchResults = .loaded(found)
        } catch {
            guard self.submitted == submitted, self.filter == filter else { return }
            searchResults = .failed(error.friendlyMessage)
        }
    }

    func clearSearch() {
        submitted = nil
        searchResults = nil
        query = ""
        filter = .all
    }

    func loadMoreSearch() async {
        guard !isLoadingMoreSearch, let current = searchResults?.value, let token = current.continuation else { return }
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        do {
            let (videos, channels, playlists, continuation) = try await self.videos.searchMore(token)
            guard let results = searchResults?.value else { return }
            var merged = results
            merged.videos += videos
            merged.channels += channels
            merged.playlists += playlists
            merged.continuation = continuation
            searchResults = .loaded(merged)
        } catch { }
    }

    // MARK: - Playlist

    func loadPlaylist(_ id: String) async {
        playlist = .loading
        do {
            let found = try await videos.playlist(id)
            playlist = .loaded(found)
        } catch {
            playlist = .failed(error.friendlyMessage)
        }
    }

    func loadMorePlaylist() async {
        guard !isLoadingMorePlaylist, let current = playlist?.value, let token = current.continuation else { return }
        isLoadingMorePlaylist = true
        defer { isLoadingMorePlaylist = false }
        do {
            let (items, continuation) = try await videos.playlistMore(token)
            guard let page = playlist?.value else { return }
            var merged = page
            merged.items += items
            merged.continuation = continuation
            playlist = .loaded(merged)
        } catch { }
    }

    // MARK: - Watch

    func loadWatch(_ id: String) async {
        watch = .loading
        do {
            let found = try await videos.watch(id)
            watch = .loaded(found)
        } catch {
            watch = .failed(error.friendlyMessage)
        }
    }
}

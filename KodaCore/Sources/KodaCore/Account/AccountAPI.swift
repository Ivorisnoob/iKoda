import Foundation

/// The signed-in account's own pages and writes, all on music.youtube.com as WEB_REMIX
/// and signed with `accounts`' active session. Each throws `MusicError.signedOut` with
/// no session or when YouTube answers as signed out. Shapes and endpoints follow Koda
/// for Android (YouTubeAccount.kt, MusicPlaylists.kt, PlaylistEditing.kt, WatchPage.kt).
extension YouTubeMusic {
    // MARK: Who

    /// Name, handle, photo and datasyncId of the active session's account.
    public func accountInfo() async throws -> AccountInfo {
        let root = try await api.music("account/account_menu", [:], signing: .required)
        guard let info = AccountPages.accountInfo(root) else { throw MusicError.badResponse(200) }
        return info
    }

    // MARK: Library

    /// Liked songs, newest first, every page up to `limit`. All or nothing: a page that
    /// fails throws rather than returning part of the list, which a sync would read as
    /// unlikes.
    public func likedSongs(limit: Int = 5000) async throws -> [Song] {
        let items = try await library("FEmusic_liked_videos", limit: limit)
        return items.compactMap { if case .song(let song) = $0 { return song }; return nil }
    }

    /// Playlists in the library: the account's own and ones it saved. Liked Music and
    /// Episodes for Later are left out; liked songs come from `likedSongs`.
    public func libraryPlaylists() async throws -> [PlaylistSummary] {
        try await library("FEmusic_liked_playlists").compactMap {
            if case .playlist(let p) = $0, p.id != "LM", p.id != "SE" { return p }
            return nil
        }
    }

    public func libraryAlbums() async throws -> [AlbumSummary] {
        try await library("FEmusic_liked_albums").compactMap { if case .album(let a) = $0 { return a }; return nil }
    }

    /// Artists the account subscribes to.
    public func libraryArtists() async throws -> [ArtistSummary] {
        try await library("FEmusic_library_corpus_artists").compactMap { if case .artist(let a) = $0 { return a }; return nil }
    }

    /// A library page and its continuations.
    private func library(_ browseId: String, limit: Int = 5000) async throws -> [MusicItem] {
        var root = try await api.music("browse", ["browseId": browseId], signing: .required)
        var items = AccountPages.libraryItems(root)
        var seen = Set<String>()
        // 100 rows a page: 80 pages is past any library, so a chain that long isn't ending.
        while items.count < limit, seen.count < 80, let token = AccountPages.libraryContinuation(root), seen.insert(token).inserted {
            try Task.checkCancellation()
            root = try await api.music("browse", ["continuation": token], signing: .required)
            items += AccountPages.libraryItems(root)
        }
        return Array(Pages.dedupe(items).prefix(limit))
    }

    // MARK: Writes

    /// Like or unlike a song; liked songs are the account's Liked Music.
    public func setLiked(videoId: String, liked: Bool) async throws {
        _ = try await api.music(liked ? "like/like" : "like/removelike", ["target": ["videoId": videoId]], signing: .required)
    }

    /// Save an album or playlist to the library, or remove it. An album is saved by its
    /// audio playlist (`OLAK5uy…`, `AlbumPage.audioPlaylistId`), not its `MPRE…` id.
    public func setSaved(playlistId: String, saved: Bool) async throws {
        let id = String(playlistId.trimmingPrefix("VL"))
        _ = try await api.music(saved ? "like/like" : "like/removelike", ["target": ["playlistId": id]], signing: .required)
    }

    /// Subscribe to an artist's channel (`UC…`), or unsubscribe.
    public func setSubscribed(channelId: String, subscribed: Bool) async throws {
        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        _ = try await api.music(endpoint, ["channelIds": [channelId]], signing: .required)
    }

    /// A new playlist on the account, with `videoIds` in order; returns its id. Long lists
    /// go in batches (100 with the create, then 50 per edit), as Android verified lands
    /// every row.
    public func createPlaylist(title: String, description: String? = nil, privacy: PlaylistPrivacy = .private,
                               videoIds: [String] = []) async throws -> String {
        var payload: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
        if let description, !description.isEmpty { payload["description"] = description }
        let first = Array(videoIds.prefix(100))
        if !first.isEmpty { payload["videoIds"] = first }
        let root = try await api.music("playlist/create", payload, signing: .required)
        guard let id = AccountPages.createdPlaylistId(root) else { throw MusicError.badResponse(200) }
        if videoIds.count > first.count {
            try await addToPlaylist(playlistId: id, videoIds: Array(videoIds.dropFirst(first.count)))
        }
        return id
    }

    /// Add songs to one of the account's playlists, 50 per edit.
    public func addToPlaylist(playlistId: String, videoIds: [String]) async throws {
        let id = String(playlistId.trimmingPrefix("VL"))
        for start in stride(from: 0, to: videoIds.count, by: 50) {
            if start > 0 { try await Task.sleep(for: .milliseconds(400)) }
            let actions = videoIds[start..<min(start + 50, videoIds.count)].map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0] }
            try await editPlaylist(id, actions: actions)
        }
    }

    /// Remove a song from one of the account's playlists. With its `setVideoId` (the row's
    /// own id) just that row goes; without it, the song wherever it appears.
    public func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String? = nil) async throws {
        let action: [String: String] = if let setVideoId {
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": videoId]
        } else {
            ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId]
        }
        try await editPlaylist(String(playlistId.trimmingPrefix("VL")), actions: [action])
    }

    /// Delete one of the account's own playlists.
    public func deletePlaylist(playlistId: String) async throws {
        _ = try await api.music("playlist/delete", ["playlistId": String(playlistId.trimmingPrefix("VL"))], signing: .required)
    }

    /// The account's playlists songs can be added to, for "Add to playlist". Given the
    /// songs, YouTube's own list (`playlist/get_add_to_playlist`), which has only
    /// playlists the account can edit; music.youtube.com doesn't say which already hold
    /// them. Without songs, the library's `PL…` playlists, as Android's sheet does,
    /// which can include saved playlists of other people that refuse edits.
    public func editablePlaylists(for videoIds: [String] = []) async throws -> [EditablePlaylist] {
        if videoIds.isEmpty {
            return try await libraryPlaylists().filter { $0.id.hasPrefix("PL") }.map { EditablePlaylist(id: $0.id, title: $0.title) }
        }
        let root = try await api.music("playlist/get_add_to_playlist", ["videoIds": videoIds], signing: .required)
        return AccountPages.addToPlaylistOptions(root)
    }

    private func editPlaylist(_ playlistId: String, actions: [[String: String]]) async throws {
        let root = try await api.music("browse/edit_playlist", ["playlistId": playlistId, "actions": actions], signing: .required)
        guard AccountPages.editSucceeded(root) else { throw MusicError.badResponse(200) }
    }
}

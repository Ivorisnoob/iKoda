import Foundation

/// What a signed-in account holds, as one sync read it.
public struct AccountLibrary: Sendable {
    public var liked: [Song]
    public var albums: [AlbumSummary]
    public var playlists: [PlaylistSummary]
    public var artists: [ArtistSummary]

    public init(liked: [Song] = [], albums: [AlbumSummary] = [], playlists: [PlaylistSummary] = [], artists: [ArtistSummary] = []) {
        self.liked = liked
        self.albums = albums
        self.playlists = playlists
        self.artists = artists
    }
}

/// A profile's memory of its account between syncs: what the account held last time, and the
/// listener's own changes that haven't reached it yet. Kept in the profile's folder.
///
/// It is what lets a sync tell "removed on the account" (drop it here too) from "only ever
/// here" (keep it), and keeps a change made offline from being undone by the next sync.
public struct AccountMirror: Codable, Sendable, Equatable {
    public var liked: Set<String> = []
    public var albums: Set<String> = []
    public var playlists: Set<String> = []
    public var artists: Set<String> = []
    /// Oldest first, one per item: a newer change to the same item replaces the older.
    public private(set) var pending: [LibraryChange] = []

    public init() {}

    public mutating func queue(_ change: LibraryChange) {
        pending.removeAll { $0.target == change.target }
        pending.append(change)
    }

    /// The change reached the account; a newer one to the same item stays queued.
    public mutating func sent(_ change: LibraryChange) {
        pending.removeAll { $0 == change }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = try c.decodeIfPresent(Set<String>.self, forKey: .liked) ?? []
        albums = try c.decodeIfPresent(Set<String>.self, forKey: .albums) ?? []
        playlists = try c.decodeIfPresent(Set<String>.self, forKey: .playlists) ?? []
        artists = try c.decodeIfPresent(Set<String>.self, forKey: .artists) ?? []
        pending = try c.decodeIfPresent([LibraryChange].self, forKey: .pending) ?? []
    }

    /// Ids with an unsent change, by whether the listener added or removed them.
    func unsent(_ kind: LibraryChange.Kind, adding: Bool) -> Set<String> {
        Set(pending.filter { $0.target.kind == kind && $0.isOn == adding }.map(\.target.id))
    }
}

extension Library {
    /// Bring in what the account holds and take out what was removed from it since the last
    /// sync, then remember what it holds now. Something only ever kept here stays, and so does
    /// anything with a change still waiting to be sent: an unlike made offline isn't liked again,
    /// a like made offline isn't dropped.
    public func reconcile(with account: AccountLibrary, mirror: inout AccountMirror) {
        func incoming<T: Identifiable>(_ items: [T], _ kind: LibraryChange.Kind) -> [T] where T.ID == String {
            let removedHere = mirror.unsent(kind, adding: false)
            return items.filter { !removedHere.contains($0.id) }
        }
        func gone(_ previous: Set<String>, _ now: [String], _ kind: LibraryChange.Kind) -> Set<String> {
            previous.subtracting(now).subtracting(mirror.unsent(kind, adding: true))
        }
        mergeAccount(liked: incoming(account.liked, .liked), albums: incoming(account.albums, .album),
                     playlists: incoming(account.playlists, .playlist), artists: incoming(account.artists, .artist))
        let goneLiked = gone(mirror.liked, account.liked.map(\.id), .liked)
        let goneAlbums = gone(mirror.albums, account.albums.map(\.id), .album)
        let gonePlaylists = gone(mirror.playlists, account.playlists.map(\.id), .playlist)
        let goneArtists = gone(mirror.artists, account.artists.map(\.id), .artist)
        if !(goneLiked.isEmpty && goneAlbums.isEmpty && gonePlaylists.isEmpty && goneArtists.isEmpty) {
            dropMissing(liked: Set(liked.map(\.id)).subtracting(goneLiked),
                        albums: Set(albums.map(\.id)).subtracting(goneAlbums),
                        playlists: Set(playlists.map(\.id)).subtracting(gonePlaylists),
                        artists: Set(artists.map(\.id)).subtracting(goneArtists))
        }
        mirror.liked = Set(account.liked.map(\.id))
        mirror.albums = Set(account.albums.map(\.id))
        mirror.playlists = Set(account.playlists.map(\.id))
        mirror.artists = Set(account.artists.map(\.id))
    }
}

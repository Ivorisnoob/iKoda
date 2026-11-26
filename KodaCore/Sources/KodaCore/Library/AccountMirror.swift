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
    /// Changes the account took that no read has shown yet. YouTube's library pages lag a write
    /// (and a sync's read may have left before the write did), so until a read agrees, or
    /// `settleTime` passes, a sync treats them as still on their way: an unliked song isn't
    /// liked again from a list that still holds it.
    public private(set) var settling: [Settling] = []

    public struct Settling: Codable, Sendable, Equatable {
        public var change: LibraryChange
        public var sent: Date
    }

    /// Long enough for YouTube's lists to catch up; past it the account's word stands, so a
    /// change it took and then didn't keep isn't hidden for ever.
    public static let settleTime: TimeInterval = 60 * 60

    public init() {}

    public mutating func queue(_ change: LibraryChange) {
        pending.removeAll { $0.target == change.target }
        settling.removeAll { $0.change.target == change.target }
        pending.append(change)
    }

    /// The change reached the account; a newer one to the same item stays queued.
    public mutating func sent(_ change: LibraryChange, at date: Date = Date()) {
        guard pending.contains(change) else { return }
        pending.removeAll { $0 == change }
        settling.append(Settling(change: change, sent: date))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = try c.decodeIfPresent(Set<String>.self, forKey: .liked) ?? []
        albums = try c.decodeIfPresent(Set<String>.self, forKey: .albums) ?? []
        playlists = try c.decodeIfPresent(Set<String>.self, forKey: .playlists) ?? []
        artists = try c.decodeIfPresent(Set<String>.self, forKey: .artists) ?? []
        pending = try c.decodeIfPresent([LibraryChange].self, forKey: .pending) ?? []
        settling = try c.decodeIfPresent([Settling].self, forKey: .settling) ?? []
    }

    /// Ids with a change the account hasn't shown yet (unsent, or sent and not read back), by
    /// whether the listener added or removed them.
    func unsent(_ kind: LibraryChange.Kind, adding: Bool) -> Set<String> {
        let changes = pending + settling.map(\.change)
        return Set(changes.filter { $0.target.kind == kind && $0.isOn == adding }.map(\.target.id))
    }

    /// Forget the settling changes this read shows, and those past `settleTime`.
    mutating func settle(with account: AccountLibrary, at now: Date) {
        let held: [LibraryChange.Kind: Set<String>] = [
            .liked: Set(account.liked.map(\.id)), .album: Set(account.albums.map(\.id)),
            .playlist: Set(account.playlists.map(\.id)), .artist: Set(account.artists.map(\.id)),
        ]
        settling.removeAll { item in
            let target = item.change.target
            let shown = held[target.kind, default: []].contains(target.id) == item.change.isOn
            return shown || now.timeIntervalSince(item.sent) > Self.settleTime
        }
    }
}

extension Library {
    /// Bring in what the account holds and take out what was removed from it since the last
    /// sync, then remember what it holds now. Something only ever kept here stays, and so does
    /// anything with a change still waiting to be sent: an unlike made offline isn't liked again,
    /// a like made offline isn't dropped. Nor is either undone by a read that hasn't caught up
    /// with a change already sent (`AccountMirror.settling`).
    public func reconcile(with account: AccountLibrary, mirror: inout AccountMirror, at now: Date = Date()) {
        mirror.settle(with: account, at: now)
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

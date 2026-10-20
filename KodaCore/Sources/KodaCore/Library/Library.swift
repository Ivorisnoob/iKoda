import Foundation
import Observation

/// What the listener keeps on this phone: songs they liked, albums, playlists
/// and artists they saved, playlists they made, what they played and searched,
/// and how long they listened. One JSON file per profile, written after each
/// change.
@MainActor
@Observable
public final class Library {
    public private(set) var liked: [Song] = []
    public private(set) var albums: [AlbumSummary] = []
    public private(set) var playlists: [PlaylistSummary] = []
    public private(set) var artists: [ArtistSummary] = []
    /// Most recent first, one entry per song.
    public private(set) var recent: [Song] = []
    public private(set) var searches: [String] = []
    /// Playlists made on this phone, newest first.
    public private(set) var userPlaylists: [UserPlaylist] = []
    /// Play counts and listening time per song, by video id.
    public private(set) var songStats: [String: SongStats] = [:]
    /// Seconds listened per day, keyed `yyyy-MM-dd` in the phone's time zone.
    public private(set) var dailyListening: [String: TimeInterval] = [:]
    /// Seconds to shift synced lyrics by, per video id; positive shows lines later.
    public private(set) var lyricsOffsets: [String: TimeInterval] = [:]
    /// The songs the signed-in YouTube account liked, as of the last sync.
    /// A mirror of the account, not the listener's own likes: they keep both.
    public private(set) var accountLiked: [Song] = []
    /// The playlists in the signed-in account's YouTube Music library.
    public private(set) var accountPlaylists: [PlaylistSummary] = []
    /// When the account's library was last read.
    public private(set) var accountSyncedAt: Date?
    /// The name of the signed-in account, as YouTube gave it.
    public private(set) var accountName: String?
    /// The newest play taken from a Koda for Android backup, so importing the same backup,
    /// or a later one that repeats its history, never counts a play twice.
    private var androidPlaysImportedThrough: Date?

    private let directory: URL?
    /// The profile whose library this is. Every profile keeps its own, so
    /// switching profiles changes what the library holds.
    private var profileID: UUID
    private static let recentLimit = 200
    private static let searchLimit = 20
    /// Listening time arrives every few seconds; it is written with the next change or `flush()`.
    private var hasUnsavedListening = false

    public init(directory: URL?, profileID: UUID = Library.localProfileID) {
        self.directory = directory
        self.profileID = profileID
        load()
    }

    /// The profile a library belongs to when none is named: the one on this
    /// device.
    public static let localProfileID = UUID(uuidString: "6B1E4A2C-0D3F-4E7A-9C51-8F2D5A0B7E10")!

    /// The profile whose library is loaded.
    public var owner: UUID { profileID }

    /// Another profile's library: what this one holds changes, and the
    /// profile that was left keeps everything it had.
    public func activate(_ id: UUID) {
        guard id != profileID else { return }
        save()
        profileID = id
        // The profile that was left is written out; what is in memory now
        // belongs to the profile that was chosen.
        apply(Snapshot())
        load()
    }

    /// A new profile starts with a copy of what another profile had, so that
    /// signing in from a profile on this device takes nothing away.
    ///
    /// The copy is never over an existing library: a profile that has one
    /// keeps it.
    public func copyLibrary(from source: UUID, to destination: UUID) {
        guard let directory else { return }
        let from = directory.appending(path: "profile-\(source.uuidString).json")
        let to = directory.appending(path: "profile-\(destination.uuidString).json")
        guard !FileManager.default.fileExists(atPath: to.path) else { return }
        // What is in memory belongs to the profile it was made in, so it is
        // written out before it is copied.
        if source == profileID { save() }
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.copyItem(at: from, to: to)
    }

    // MARK: Songs

    public func isLiked(_ song: Song) -> Bool { liked.contains { $0.id == song.id } }

    public func toggleLike(_ song: Song) {
        if let index = liked.firstIndex(where: { $0.id == song.id }) {
            liked.remove(at: index)
        } else {
            liked.insert(song, at: 0)
        }
        save()
    }

    public func recordPlay(_ song: Song, at date: Date = Date()) {
        recent.removeAll { $0.id == song.id }
        recent.insert(song, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        var stats = songStats[song.id] ?? SongStats(song: song, firstPlayed: date)
        stats.song = song
        stats.plays += 1
        stats.lastPlayed = date
        songStats[song.id] = stats
        save()
    }

    /// Credit `seconds` of listening to `song` on the day of `date`.
    public func addListening(_ seconds: TimeInterval, to song: Song, at date: Date = Date()) {
        guard seconds > 0 else { return }
        var stats = songStats[song.id] ?? SongStats(song: song, firstPlayed: date)
        stats.seconds += seconds
        songStats[song.id] = stats
        dailyListening[Self.dayKey(date), default: 0] += seconds
        hasUnsavedListening = true
    }

    /// Write listening time gathered since the last save.
    public func flush() {
        if hasUnsavedListening { save() }
    }

    public func clearHistory() {
        recent = []
        save()
    }

    /// Forget play counts and listening time; history and likes stay.
    public func clearStats() {
        songStats = [:]
        dailyListening = [:]
        save()
    }

    public func plays(of song: Song) -> Int { songStats[song.id]?.plays ?? 0 }

    // MARK: Collections

    public func isSaved(album id: String) -> Bool { albums.contains { $0.id == id } }
    public func isSaved(playlist id: String) -> Bool { playlists.contains { $0.id == id } }
    public func isSaved(artist id: String) -> Bool { artists.contains { $0.id == id } }

    public func toggleSave(_ album: AlbumSummary) {
        toggle(album, in: &albums)
        save()
    }

    public func toggleSave(_ playlist: PlaylistSummary) {
        toggle(playlist, in: &playlists)
        save()
    }

    public func toggleSave(_ artist: ArtistSummary) {
        toggle(artist, in: &artists)
        save()
    }

    private func toggle<T: Identifiable>(_ item: T, in list: inout [T]) {
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list.remove(at: index)
        } else {
            list.insert(item, at: 0)
        }
    }

    // MARK: Playlists made here

    public func userPlaylist(_ id: UUID) -> UserPlaylist? { userPlaylists.first { $0.id == id } }

    @discardableResult
    public func createPlaylist(named name: String, songs: [Song] = [], at date: Date = Date()) -> UserPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = UserPlaylist(name: trimmed.isEmpty ? "New Playlist" : trimmed, songs: Self.unique(songs), created: date)
        userPlaylists.insert(playlist, at: 0)
        save()
        return playlist
    }

    public func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editPlaylist(id) { $0.name = trimmed }
    }

    public func deletePlaylist(_ id: UUID) {
        userPlaylists.removeAll { $0.id == id }
        save()
    }

    /// Append the songs the playlist does not already hold; returns how many were added.
    @discardableResult
    public func add(_ songs: [Song], toPlaylist id: UUID) -> Int {
        var added = 0
        editPlaylist(id) { playlist in
            let known = Set(playlist.songs.map(\.id))
            let fresh = Self.unique(songs).filter { !known.contains($0.id) }
            playlist.songs += fresh
            added = fresh.count
        }
        return added
    }

    public func removeSongs(atOffsets offsets: IndexSet, fromPlaylist id: UUID) {
        editPlaylist(id) { playlist in
            for index in offsets.sorted(by: >) where playlist.songs.indices.contains(index) {
                playlist.songs.remove(at: index)
            }
        }
    }

    public func moveSongs(fromOffsets source: IndexSet, toOffset destination: Int, inPlaylist id: UUID) {
        editPlaylist(id) { playlist in
            let valid = source.filter { playlist.songs.indices.contains($0) }
            guard !valid.isEmpty else { return }
            let moving = valid.map { playlist.songs[$0] }
            let insertAt = min(max(destination, 0), playlist.songs.count) - valid.filter { $0 < destination }.count
            for index in valid.reversed() { playlist.songs.remove(at: index) }
            playlist.songs.insert(contentsOf: moving, at: insertAt)
        }
    }

    private func editPlaylist(_ id: UUID, _ change: (inout UserPlaylist) -> Void) {
        guard let index = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        change(&userPlaylists[index])
        userPlaylists[index].modified = Date()
        save()
    }

    private static func unique(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    // MARK: Lyrics timing

    public func lyricsOffset(for songId: String) -> TimeInterval { lyricsOffsets[songId] ?? 0 }

    /// Rounded to a tenth of a second; zero removes the entry.
    public func setLyricsOffset(_ offset: TimeInterval, for songId: String) {
        let rounded = (offset * 10).rounded() / 10
        lyricsOffsets[songId] = rounded == 0 ? nil : rounded
        save()
    }

    // MARK: Search history

    public func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searches.insert(trimmed, at: 0)
        if searches.count > Self.searchLimit { searches.removeLast(searches.count - Self.searchLimit) }
        save()
    }

    public func removeSearch(_ query: String) {
        searches.removeAll { $0 == query }
        save()
    }

    public func clearSearches() {
        searches = []
        save()
    }

    // MARK: The signed-in account

    /// Replace the mirror of the signed-in account's library: the songs it
    /// liked and the playlists in it. Nothing of the listener's own is
    /// touched, so a sync can never take a local like away.
    public func applyAccountSync(liked: [Song], playlists: [PlaylistSummary], name: String?, at date: Date = Date()) {
        accountLiked = liked
        accountPlaylists = playlists
        accountName = name
        accountSyncedAt = date
        save()
    }

    /// Forget the signed-in account's library, when the account goes away.
    public func clearAccountData() {
        accountLiked = []
        accountPlaylists = []
        accountSyncedAt = nil
        accountName = nil
        save()
    }

    // MARK: Days

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Seconds listened on the day of `date`.
    public func listening(on date: Date, calendar: Calendar = .current) -> TimeInterval {
        dailyListening[Self.dayKey(date, calendar: calendar)] ?? 0
    }

    /// Days in a row with any listening, ending today, or yesterday while today has none yet.
    public func streak(asOf date: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: date)
        if listening(on: day, calendar: calendar) == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var count = 0
        while listening(on: day, calendar: calendar) > 0 {
            count += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = before
        }
        return count
    }

    // MARK: Storage

    private struct Snapshot: Codable {
        var liked: [Song] = []
        var albums: [AlbumSummary] = []
        var playlists: [PlaylistSummary] = []
        var artists: [ArtistSummary] = []
        var recent: [Song] = []
        var searches: [String] = []
        var userPlaylists: [UserPlaylist] = []
        var songStats: [String: SongStats] = [:]
        var dailyListening: [String: TimeInterval] = [:]
        var lyricsOffsets: [String: TimeInterval] = [:]
        var androidPlaysImportedThrough: Date?
        var accountLiked: [Song] = []
        var accountPlaylists: [PlaylistSummary] = []
        var accountSyncedAt: Date?
        var accountName: String?

        init() {}

        // A file from an older version lacks the newer keys; each missing one starts empty rather than failing the whole file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            liked = try c.decodeIfPresent([Song].self, forKey: .liked) ?? []
            albums = try c.decodeIfPresent([AlbumSummary].self, forKey: .albums) ?? []
            playlists = try c.decodeIfPresent([PlaylistSummary].self, forKey: .playlists) ?? []
            artists = try c.decodeIfPresent([ArtistSummary].self, forKey: .artists) ?? []
            recent = try c.decodeIfPresent([Song].self, forKey: .recent) ?? []
            searches = try c.decodeIfPresent([String].self, forKey: .searches) ?? []
            userPlaylists = try c.decodeIfPresent([UserPlaylist].self, forKey: .userPlaylists) ?? []
            songStats = try c.decodeIfPresent([String: SongStats].self, forKey: .songStats) ?? [:]
            dailyListening = try c.decodeIfPresent([String: TimeInterval].self, forKey: .dailyListening) ?? [:]
            lyricsOffsets = try c.decodeIfPresent([String: TimeInterval].self, forKey: .lyricsOffsets) ?? [:]
            androidPlaysImportedThrough = try c.decodeIfPresent(Date.self, forKey: .androidPlaysImportedThrough)
            accountLiked = try c.decodeIfPresent([Song].self, forKey: .accountLiked) ?? []
            accountPlaylists = try c.decodeIfPresent([PlaylistSummary].self, forKey: .accountPlaylists) ?? []
            accountSyncedAt = try c.decodeIfPresent(Date.self, forKey: .accountSyncedAt)
            accountName = try c.decodeIfPresent(String.self, forKey: .accountName)
        }
    }

    private var file: URL? {
        directory?.appending(path: "profile-\(profileID.uuidString).json")
    }

    /// The library this install had before it had profiles. It belongs to the
    /// profile that was active when the roster arrived, and is copied, never
    /// moved, so nothing is lost if the copy fails.
    private var legacyFile: URL? {
        directory?.appending(path: "library.json")
    }

    private func load() {
        guard let file else { return }
        if !FileManager.default.fileExists(atPath: file.path),
           let legacy = legacyFile, FileManager.default.fileExists(atPath: legacy.path) {
            // The library this install had before it had profiles belongs to
            // the profile that was active; it is copied once, and the old
            // file goes, so it is never copied into another profile later.
            if (try? FileManager.default.copyItem(at: legacy, to: file)) != nil {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        liked = snapshot.liked
        albums = snapshot.albums
        playlists = snapshot.playlists
        artists = snapshot.artists
        recent = snapshot.recent
        searches = snapshot.searches
        userPlaylists = snapshot.userPlaylists
        songStats = snapshot.songStats
        dailyListening = snapshot.dailyListening
        lyricsOffsets = snapshot.lyricsOffsets
        androidPlaysImportedThrough = snapshot.androidPlaysImportedThrough
        accountLiked = snapshot.accountLiked
        accountPlaylists = snapshot.accountPlaylists
        accountSyncedAt = snapshot.accountSyncedAt
        accountName = snapshot.accountName
    }

    private func save() {
        hasUnsavedListening = false
        guard let file else { return }
        guard let data = try? JSONEncoder().encode(snapshot()) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.liked = liked
        snapshot.albums = albums
        snapshot.playlists = playlists
        snapshot.artists = artists
        snapshot.recent = recent
        snapshot.searches = searches
        snapshot.userPlaylists = userPlaylists
        snapshot.songStats = songStats
        snapshot.dailyListening = dailyListening
        snapshot.lyricsOffsets = lyricsOffsets
        snapshot.androidPlaysImportedThrough = androidPlaysImportedThrough
        snapshot.accountLiked = accountLiked
        snapshot.accountPlaylists = accountPlaylists
        snapshot.accountSyncedAt = accountSyncedAt
        snapshot.accountName = accountName
        return snapshot
    }

    // MARK: Backup

    public enum BackupError: LocalizedError {
        case notABackup

        public var errorDescription: String? { "This file isn't a Koda library backup." }
    }

    private static let backupFormat = "koda-ios-library"

    private struct Backup: Codable {
        var format: String
        var version: Int
        var exported: Date
        var library: Snapshot
    }

    /// Everything in the library as one JSON file, for keeping or moving to another phone.
    public func backupData(at date: Date = Date()) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Backup(format: Self.backupFormat, version: 1, exported: date, library: snapshot()))
    }

    /// Replace the library with a backup. Nothing changes unless the whole file reads as one.
    public func restore(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data), backup.format == Self.backupFormat else {
            throw BackupError.notABackup
        }
        apply(backup.library)
        save()
    }
}

// MARK: - Koda for Android

/// What an Android import added, to tell the listener.
public struct AndroidImportSummary: Sendable, Equatable {
    public var likedSongs = 0
    public var plays = 0
    public var playlists = 0
    public var saved = 0
    public var searches = 0

    public var isEmpty: Bool { likedSongs + plays + playlists + saved + searches == 0 }
}

extension Library {
    /// Add a Koda for Android backup to the library. Nothing here is replaced: likes, saved
    /// albums and playlists join what's already saved, plays add to the stats and history,
    /// and a playlist already here under the same name with the same songs isn't added again.
    @discardableResult
    public func importAndroid(_ backup: AndroidBackup, calendar: Calendar = .current) -> AndroidImportSummary {
        var summary = AndroidImportSummary()

        let likedIds = Set(liked.map(\.id))
        let newLikes = backup.liked.filter { !likedIds.contains($0.id) }
        liked += newLikes
        summary.likedSongs = newLikes.count

        for album in backup.albums where !isSaved(album: album.id) {
            albums.insert(album, at: 0)
            summary.saved += 1
        }
        for playlist in backup.savedPlaylists where !isSaved(playlist: playlist.id) {
            playlists.insert(playlist, at: 0)
            summary.saved += 1
        }

        for playlist in backup.playlists {
            let ids = playlist.songs.map(\.id)
            guard !userPlaylists.contains(where: { $0.name == playlist.name && $0.songs.map(\.id) == ids }) else { continue }
            userPlaylists.append(UserPlaylist(name: playlist.name, songs: playlist.songs, created: playlist.created))
            summary.playlists += 1
        }
        userPlaylists.sort { $0.created > $1.created }

        let fresh = backup.plays.filter { play in androidPlaysImportedThrough.map { play.date > $0 } ?? true }
        for play in fresh {
            var stats = songStats[play.song.id] ?? SongStats(song: play.song, firstPlayed: play.date)
            stats.plays += 1
            stats.seconds += play.seconds
            stats.firstPlayed = min(stats.firstPlayed, play.date)
            stats.lastPlayed = max(stats.lastPlayed, play.date)
            songStats[play.song.id] = stats
            dailyListening[Self.dayKey(play.date, calendar: calendar), default: 0] += play.seconds
        }
        summary.plays = fresh.count
        if let newest = fresh.last?.date { androidPlaysImportedThrough = newest }

        // Recently played, newest first across both: each song where it was last played.
        var lastPlayed: [String: (Song, Date)] = [:]
        for song in recent { lastPlayed[song.id] = (song, songStats[song.id]?.lastPlayed ?? .distantPast) }
        for play in fresh where (lastPlayed[play.song.id]?.1 ?? .distantPast) < play.date {
            lastPlayed[play.song.id] = (lastPlayed[play.song.id]?.0 ?? play.song, play.date)
        }
        recent = lastPlayed.values.sorted { $0.1 > $1.1 }.prefix(Self.recentLimit).map(\.0)

        let known = Set(searches.map { $0.lowercased() })
        let newSearches = backup.searches.filter { !known.contains($0.lowercased()) }
        let searchesBefore = searches.count
        searches = Array((searches + newSearches).prefix(Self.searchLimit))
        summary.searches = searches.count - searchesBefore

        save()
        return summary
    }
}

/// A playlist made on this phone.
public struct UserPlaylist: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var songs: [Song]
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), name: String, songs: [Song] = [], created: Date = Date()) {
        self.id = id
        self.name = name
        self.songs = songs
        self.created = created
        modified = created
    }

    public var duration: TimeInterval { songs.compactMap(\.duration).reduce(0, +) }
}

/// How much one song has been played.
public struct SongStats: Hashable, Codable, Sendable {
    public var song: Song
    public var plays = 0
    public var seconds: TimeInterval = 0
    public var firstPlayed: Date
    public var lastPlayed: Date

    public init(song: Song, firstPlayed: Date) {
        self.song = song
        self.firstPlayed = firstPlayed
        lastPlayed = firstPlayed
    }
}

import Foundation
import Observation

/// What one profile keeps on this device: songs they liked, albums, playlists and artists
/// they saved, playlists they made, what they played and searched, how long they listened
/// and what they asked not to be offered. Two JSON files in the profile's folder: the
/// library, and the dated history of plays, which grows and changes on its own.
///
/// One `Library` serves the whole app; switching profile points it at another folder with
/// `open(directory:)`, so views holding it see the new profile's library at once.
@MainActor
@Observable
public final class Library {
    public private(set) var liked: [Song] = []
    public private(set) var albums: [AlbumSummary] = []
    public private(set) var playlists: [PlaylistSummary] = []
    public private(set) var artists: [ArtistSummary] = []
    /// Most recent first, one entry per song.
    public private(set) var recent: [Song] = []
    /// Every play, newest first, with when it happened; capped at `historyLimit`.
    public private(set) var history: [PlayEvent] = []
    public private(set) var searches: [String] = []
    /// Playlists made on this device, newest first.
    public private(set) var userPlaylists: [UserPlaylist] = []
    /// Play counts and listening time per song, by video id.
    public private(set) var songStats: [String: SongStats] = [:]
    /// Seconds listened per day, keyed `yyyy-MM-dd` in the device's time zone.
    public private(set) var dailyListening: [String: TimeInterval] = [:]
    /// Seconds to shift synced lyrics by, per video id; positive shows lines later.
    public private(set) var lyricsOffsets: [String: TimeInterval] = [:]
    /// Songs and artists the listener doesn't want offered again.
    public private(set) var notInterested = NotInterested()
    /// The artists, genres and songs picked in taste setup.
    public private(set) var taste = TasteProfile()
    /// Videos watched, most recent first, one entry each: Continue Watching, and what a
    /// signed-out video Home is built from.
    public private(set) var watched: [Video] = []
    /// The newest play taken from a Koda for Android backup, so importing the same backup,
    /// or a later one that repeats its history, never counts a play twice.
    private var androidPlaysImportedThrough: Date?

    /// Told about the listener's own likes and saves, not about ones `mergeAccount` brings in:
    /// for sending them to a signed-in account.
    @ObservationIgnored public var onChange: ((LibraryChange) -> Void)?

    /// The folder the library is read from and written to; nil keeps it in memory only.
    public private(set) var directory: URL?
    private var file: URL? { directory?.appending(path: "library.json") }
    private var historyFile: URL? { directory?.appending(path: "history.json") }
    private static let recentLimit = 200
    private static let searchLimit = 20
    static let watchedLimit = 200
    static let historyLimit = 3000
    /// Listening time arrives every few seconds; it is written with the next change or `flush()`.
    @ObservationIgnored private var hasUnsavedListening = false
    @ObservationIgnored private var pendingLibrary = false
    @ObservationIgnored private var pendingHistory = false
    @ObservationIgnored private let libraryClock = SaveClock()
    @ObservationIgnored private let historyClock = SaveClock()

    public init(directory: URL?) {
        self.directory = directory
        load()
    }

    /// Switch to the library kept in `directory`, writing what the current one still holds first.
    public func open(directory: URL?) {
        guard directory != self.directory else { return }
        flush(force: true)
        self.directory = directory
        apply(Snapshot())
        history = []
        load()
    }

    // MARK: Songs

    public func isLiked(_ song: Song) -> Bool { liked.contains { $0.id == song.id } }

    public func toggleLike(_ song: Song) {
        setLiked(song, !isLiked(song))
    }

    public func setLiked(_ song: Song, _ isLiked: Bool) {
        let index = liked.firstIndex { $0.id == song.id }
        switch (isLiked, index) {
        case (true, nil): liked.insert(song, at: 0)
        case (false, let index?): liked.remove(at: index)
        default: return
        }
        save()
        onChange?(.liked(song, isLiked))
    }

    public func recordPlay(_ song: Song, at date: Date = Date()) {
        recent.removeAll { $0.id == song.id }
        recent.insert(song, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        history.insert(PlayEvent(song: song, date: date), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        var stats = songStats[song.id] ?? SongStats(song: song, firstPlayed: date)
        stats.song = song
        stats.plays += 1
        stats.lastPlayed = date
        songStats[song.id] = stats
        save()
        saveHistory()
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

    /// Write, now and on this thread, whatever hasn't reached the disk yet: for when the app is
    /// leaving the screen and may be suspended before a background write would run.
    public func flush(force: Bool = false) {
        if pendingLibrary || hasUnsavedListening || force { writeLibrary(snapshot()) }
        if pendingHistory || force { writeHistory(history) }
    }

    public func clearHistory() {
        recent = []
        history = []
        watched = []
        save()
        saveHistory()
    }

    /// Forget one play. A song with no play left in the history leaves Recently Played too.
    public func removeFromHistory(_ id: PlayEvent.ID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let songId = history.remove(at: index).song.id
        if !history.contains(where: { $0.song.id == songId }) {
            recent.removeAll { $0.id == songId }
            save()
        }
        saveHistory()
    }

    /// Forget play counts and listening time; history and likes stay.
    public func clearStats() {
        songStats = [:]
        dailyListening = [:]
        save()
    }

    public func plays(of song: Song) -> Int { songStats[song.id]?.plays ?? 0 }

    // MARK: Not interested

    public func isHidden(_ song: Song) -> Bool { notInterested.hides(song) }
    public func isHidden(artist: ArtistRef) -> Bool { notInterested.hides(artist) }

    /// Songs that may be offered: without the ones the listener asked not to hear.
    public func offerable(_ songs: [Song]) -> [Song] {
        notInterested.isEmpty ? songs : songs.filter { !notInterested.hides($0) }
    }

    public func hide(_ song: Song) {
        guard !notInterested.songs.contains(where: { $0.id == song.id }) else { return }
        notInterested.songs.insert(song, at: 0)
        save()
    }

    public func hide(artist: ArtistRef) {
        guard !notInterested.hides(artist) else { return }
        notInterested.artists.insert(artist, at: 0)
        save()
    }

    public func unhide(_ song: Song) {
        notInterested.songs.removeAll { $0.id == song.id }
        save()
    }

    public func unhide(artist: ArtistRef) {
        notInterested.artists.removeAll { NotInterested.same($0, artist) }
        save()
    }

    // MARK: Videos

    public func recordWatch(_ video: Video) {
        watched.removeAll { $0.id == video.id }
        watched.insert(video, at: 0)
        if watched.count > Self.watchedLimit { watched.removeLast(watched.count - Self.watchedLimit) }
        save()
    }

    public func removeWatched(_ id: String) {
        watched.removeAll { $0.id == id }
        save()
    }

    // MARK: Taste

    public func setTasteArtists(_ artists: [ArtistSummary]) {
        var seen = Set<String>()
        taste.artists = Array(artists.filter { seen.insert($0.id).inserted }.prefix(TasteProfile.maxArtists))
        save()
    }

    public func setTasteGenres(_ genres: [String]) {
        taste.genres = genres.filter(TasteProfile.genres.contains)
        save()
    }

    /// A song said yes to in the deck.
    public func keepTasteSong(_ song: Song) {
        taste.songs = Array(([song] + taste.songs.filter { $0.id != song.id }).prefix(TasteProfile.maxSongs))
        save()
    }

    public func dropTasteSong(_ song: Song) {
        taste.songs.removeAll { $0.id == song.id }
        save()
    }

    public func clearTaste() {
        taste = TasteProfile()
        save()
    }

    // MARK: Collections

    public func isSaved(album id: String) -> Bool { albums.contains { $0.id == id } }
    public func isSaved(playlist id: String) -> Bool { playlists.contains { $0.id == id } }
    public func isSaved(artist id: String) -> Bool { artists.contains { $0.id == id } }

    public func toggleSave(_ album: AlbumSummary) {
        let saved = toggle(album, in: &albums)
        save()
        onChange?(.album(album, saved))
    }

    public func toggleSave(_ playlist: PlaylistSummary) {
        let saved = toggle(playlist, in: &playlists)
        save()
        onChange?(.playlist(playlist, saved))
    }

    public func toggleSave(_ artist: ArtistSummary) {
        let saved = toggle(artist, in: &artists)
        save()
        onChange?(.artist(artist, saved))
    }

    /// Returns whether the item is saved afterwards.
    private func toggle<T: Identifiable>(_ item: T, in list: inout [T]) -> Bool {
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list.remove(at: index)
            return false
        }
        list.insert(item, at: 0)
        return true
    }

    /// Bring in what a signed-in account holds, without telling `onChange`: it came from there.
    /// What the account has and the library lacks is added in the account's order ahead of the
    /// rest; nothing here is removed, so a like made offline and not yet sent isn't lost.
    public func mergeAccount(liked accountLiked: [Song], albums accountAlbums: [AlbumSummary],
                             playlists accountPlaylists: [PlaylistSummary], artists accountArtists: [ArtistSummary]) {
        liked = Self.merged(accountLiked, into: liked)
        albums = Self.merged(accountAlbums, into: albums)
        playlists = Self.merged(accountPlaylists, into: playlists)
        artists = Self.merged(accountArtists, into: artists)
        save()
    }

    /// Remove what the account no longer holds, after `mergeAccount`, when the listener chose to
    /// mirror the account: likes and saves undone on another device go here too.
    public func dropMissing(liked keep: Set<String>?, albums keepAlbums: Set<String>?, playlists keepPlaylists: Set<String>?, artists keepArtists: Set<String>?) {
        if let keep { liked.removeAll { !keep.contains($0.id) } }
        if let keepAlbums { albums.removeAll { !keepAlbums.contains($0.id) } }
        if let keepPlaylists { playlists.removeAll { !keepPlaylists.contains($0.id) } }
        if let keepArtists { artists.removeAll { !keepArtists.contains($0.id) } }
        save()
    }

    private static func merged<T: Identifiable>(_ incoming: [T], into list: [T]) -> [T] where T.ID == String {
        let known = Set(list.map(\.id))
        return incoming.filter { !known.contains($0.id) } + list
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

    nonisolated struct Snapshot: Codable, Sendable {
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
        var notInterested = NotInterested()
        var taste = TasteProfile()
        var watched: [Video] = []
        var androidPlaysImportedThrough: Date?

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
            notInterested = try c.decodeIfPresent(NotInterested.self, forKey: .notInterested) ?? NotInterested()
            taste = try c.decodeIfPresent(TasteProfile.self, forKey: .taste) ?? TasteProfile()
            watched = try c.decodeIfPresent([Video].self, forKey: .watched) ?? []
            androidPlaysImportedThrough = try c.decodeIfPresent(Date.self, forKey: .androidPlaysImportedThrough)
        }
    }

    private func load() {
        if let file, let data = try? Data(contentsOf: file),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            apply(snapshot)
        }
        if let historyFile, let data = try? Data(contentsOf: historyFile),
           let events = try? JSONDecoder().decode([PlayEvent].self, from: data) {
            history = events
        }
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
        notInterested = snapshot.notInterested
        taste = snapshot.taste
        watched = snapshot.watched
        androidPlaysImportedThrough = snapshot.androidPlaysImportedThrough
    }

    /// Write the library a moment later, off the main thread, and only its newest state: with
    /// years of stats it is megabytes of JSON, which used to be encoded on the main thread after
    /// every like and every song.
    private func save() {
        hasUnsavedListening = false
        guard let file else { return }
        pendingLibrary = true
        let version = libraryClock.next()
        let snapshot = snapshot()
        let clock = libraryClock
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard clock.isNewest(version), let data = try? JSONEncoder().encode(snapshot), clock.isNewest(version) else { return }
            try? data.write(to: file, options: .atomic)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if self?.libraryClock.isNewest(version) == true { self?.pendingLibrary = false }
        }
    }

    private func saveHistory() {
        guard let historyFile else { return }
        pendingHistory = true
        let version = historyClock.next()
        let events = history
        let clock = historyClock
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard clock.isNewest(version), let data = try? JSONEncoder().encode(events), clock.isNewest(version) else { return }
            try? data.write(to: historyFile, options: .atomic)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if self?.historyClock.isNewest(version) == true { self?.pendingHistory = false }
        }
    }

    /// Synchronous writes; each bumps its clock so a background write already scheduled for an
    /// older state can't land after it.
    private func writeLibrary(_ snapshot: Snapshot) {
        _ = libraryClock.next()
        pendingLibrary = false
        hasUnsavedListening = false
        guard let file, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func writeHistory(_ events: [PlayEvent]) {
        _ = historyClock.next()
        pendingHistory = false
        guard let historyFile, let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: historyFile, options: .atomic)
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
        snapshot.notInterested = notInterested
        snapshot.taste = taste
        snapshot.watched = watched
        snapshot.androidPlaysImportedThrough = androidPlaysImportedThrough
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
        var history: [PlayEvent]?
    }

    /// Everything in the library as one JSON file, for keeping or moving to another device.
    public func backupData(at date: Date = Date()) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Backup(format: Self.backupFormat, version: 2, exported: date, library: snapshot(), history: history))
    }

    /// Replace the library with a backup. Nothing changes unless the whole file reads as one.
    public func restore(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data), backup.format == Self.backupFormat else {
            throw BackupError.notABackup
        }
        apply(backup.library)
        // A version 1 backup has no dated history; the plays it knows of become one each, at their last play.
        history = backup.history ?? backup.library.recent.compactMap { song in
            backup.library.songStats[song.id].map { PlayEvent(song: song, date: $0.lastPlayed) }
        }
        save()
        saveHistory()
    }
}

/// Something the listener did to their library that a signed-in account should hear about.
public enum LibraryChange: Codable, Hashable, Sendable {
    case liked(Song, Bool)
    case album(AlbumSummary, Bool)
    case playlist(PlaylistSummary, Bool)
    case artist(ArtistSummary, Bool)

    public enum Kind: String, Codable, Sendable {
        case liked, album, playlist, artist
    }

    /// The item the change is about, whichever way it went.
    public struct Target: Hashable, Sendable {
        public var kind: Kind
        public var id: String
    }

    public var target: Target {
        switch self {
        case .liked(let song, _): Target(kind: .liked, id: song.id)
        case .album(let album, _): Target(kind: .album, id: album.id)
        case .playlist(let playlist, _): Target(kind: .playlist, id: playlist.id)
        case .artist(let artist, _): Target(kind: .artist, id: artist.id)
        }
    }

    /// Liked or saved, rather than undone.
    public var isOn: Bool {
        switch self {
        case .liked(_, let on), .album(_, let on), .playlist(_, let on), .artist(_, let on): on
        }
    }
}

/// One play of a song.
public struct PlayEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var song: Song
    public var date: Date

    public init(song: Song, date: Date, id: UUID = UUID()) {
        self.id = id
        self.song = song
        self.date = date
    }
}

/// What the listener asked not to be offered: whole songs, and artists, every song they lead
/// or appear on. Applies to what Koda suggests (Home, mixes, radio and autoplay), never to
/// what the listener picks themselves.
public struct NotInterested: Codable, Hashable, Sendable {
    /// Newest first.
    public var songs: [Song] = []
    public var artists: [ArtistRef] = []

    public init() {}

    public var isEmpty: Bool { songs.isEmpty && artists.isEmpty }

    public func hides(_ song: Song) -> Bool {
        if songs.contains(where: { $0.id == song.id }) { return true }
        guard !artists.isEmpty else { return false }
        // Linked artists by channel id; a byline YouTube didn't link is matched on the whole line.
        let credited = song.artists.isEmpty ? [ArtistRef(id: nil, name: song.artistLine)] : song.artists
        return credited.contains(where: hides)
    }

    public func hides(_ artist: ArtistRef) -> Bool {
        artists.contains { Self.same($0, artist) }
    }

    /// The same artist: by channel id when both have one, otherwise by name.
    static func same(_ a: ArtistRef, _ b: ArtistRef) -> Bool {
        if let x = a.id, let y = b.id { return x == y }
        return a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        artists = try c.decodeIfPresent([ArtistRef].self, forKey: .artists) ?? []
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

        // The dated history, newest first across both.
        let events = history + fresh.map { PlayEvent(song: $0.song, date: $0.date) }
        let sortedEvents = events.sorted { $0.date > $1.date }
        history = Array(sortedEvents.prefix(Self.historyLimit))

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
        saveHistory()
        return summary
    }
}

/// A playlist made on this device.
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

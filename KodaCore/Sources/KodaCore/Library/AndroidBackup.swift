import Foundation

/// What Koda can take from a Koda for Android backup: liked songs, the listening history,
/// searches, the playlists made on the phone and the albums and playlists saved there.
///
/// The Android file is a zip (`manifest.json`, `profile-data.json` keyed by profile,
/// `files/playlists/<id>.json`, typed `preferences.json`; see the Android app's
/// `BackupTransfer.kt`). Everything else in it (videos, subscriptions, settings, accounts)
/// has no place here and is left out, as are songs that were files on the phone itself.
public struct AndroidBackup: Sendable {
    public struct Play: Sendable, Equatable {
        public var song: Song
        public var date: Date
        /// The song's length: Android records only plays that qualified, not how much was heard.
        public var seconds: TimeInterval
    }

    public struct Playlist: Sendable, Equatable {
        public var name: String
        public var created: Date
        public var songs: [Song]
    }

    public enum ReadError: LocalizedError, Equatable {
        case notABackup
        case newerVersion

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This file isn't a Koda for Android backup."
            case .newerVersion: "This backup was made by a newer Koda for Android than Koda here can read."
            }
        }
    }

    public var liked: [Song] = []
    /// Oldest first.
    public var plays: [Play] = []
    public var searches: [String] = []
    public var playlists: [Playlist] = []
    public var albums: [AlbumSummary] = []
    public var savedPlaylists: [PlaylistSummary] = []
    /// When the backup was made, if it says.
    public var created: Date?

    /// The newest Android format this reader knows. Later versions only add what can be
    /// skipped, unless they change the meaning of what's here, which bumps the number.
    static let knownVersion = 2

    public static func read(_ data: Data) throws -> AndroidBackup {
        guard let files = try? ZipReader(data).files() else { throw ReadError.notABackup }
        guard let manifest = files["manifest.json"].flatMap(object), manifest["format"] as? String == "koda-backup" else {
            throw ReadError.notABackup
        }
        let version = manifest["formatVersion"] as? Int ?? 0
        guard version <= knownVersion else { throw ReadError.newerVersion }

        var backup = AndroidBackup()
        if let created = manifest["createdAt"] as? Double, created > 0 { backup.created = Date(timeIntervalSince1970: created / 1000) }

        // Liked songs, history and searches: from the profile in use when the backup was made
        // (version 2), or from the device-wide copies an older backup kept.
        var likedJSON: String?
        var historyJSON: String?
        var searchText: String?
        if version >= 2, let profiles = files["profile-data.json"].flatMap(object), !profiles.isEmpty {
            let active = files["profiles.json"].flatMap(object)?["activeProfileId"] as? String
            let profile = (active.flatMap { profiles[$0] } ?? profiles.values.first) as? [String: Any] ?? [:]
            likedJSON = profile["likedSongs"] as? String
            historyJSON = profile["playHistory"] as? String
            searchText = profile["searchHistory"] as? String
        } else {
            likedJSON = files["files/liked_songs_meta.json"].map { String(decoding: $0, as: UTF8.self) }
            historyJSON = files["files/play_history.json"].map { String(decoding: $0, as: UTF8.self) }
            let preferences = files["preferences.json"].flatMap(object)
            searchText = ((preferences?["search_history"] as? [String: Any])?["history_list"] as? [String: Any])?["v"] as? String
        }

        backup.liked = array(likedJSON).compactMap(song)
        backup.plays = array(historyJSON).compactMap(play).sorted { $0.date < $1.date }
        backup.searches = (searchText ?? "").split(separator: "|").map(String.init).filter { !$0.isEmpty }

        for (path, contents) in files where path.hasPrefix("files/playlists/") && path.hasSuffix(".json") {
            guard let playlist = object(contents), let name = playlist["name"] as? String else { continue }
            let songs = (playlist["songs"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(song) }
            let created = (playlist["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            backup.playlists.append(Playlist(name: name, created: created, songs: songs))
        }
        backup.playlists.sort { $0.created > $1.created }

        let preferences = files["preferences.json"].flatMap(object)
        let savedText = ((preferences?["saved_playlists"] as? [String: Any])?["playlists"] as? [String: Any])?["v"] as? String
        for case let saved as [String: Any] in array(savedText) {
            guard let id = saved["id"] as? String, !id.isEmpty, let name = saved["name"] as? String else { continue }
            let artwork = (saved["thumbnail"] as? String).flatMap(URL.init(string:)).map { Artwork(url: $0) }
            let owner = saved["uploader"] as? String ?? ""
            // Koda opens albums by their release id; an album saved by its playlist id opens as a playlist.
            if id.hasPrefix("MPREb") {
                backup.albums.append(AlbumSummary(id: id, title: name, artistLine: owner, year: saved["releaseYear"] as? Int, artwork: artwork))
            } else {
                let playlistId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
                backup.savedPlaylists.append(PlaylistSummary(id: playlistId, title: name, subtitle: owner.isEmpty ? nil : owner, artwork: artwork))
            }
        }
        return backup
    }

    // MARK: Reading the pieces

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JSON array kept as a string inside another file, as Android stores them.
    private static func array(_ text: String?) -> [Any] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
    }

    /// A song from YouTube, from Android's `Song`. Songs that were files on the phone are left
    /// out: kotlinx leaves out values equal to their default, and a song's default source is a
    /// local file, so only songs marked YOUTUBE are YouTube's.
    static func song(_ any: Any) -> Song? {
        guard let json = any as? [String: Any], json["source"] as? String == "YOUTUBE",
              let id = json["id"] as? String, isVideoId(id),
              let title = json["title"] as? String else { return nil }
        let milliseconds = json["duration"] as? Double ?? 0
        let album = (json["albumId"] as? String).map { AlbumRef(id: $0, title: json["album"] as? String ?? "") }
        let artwork = (json["thumbnailUrl"] as? String).flatMap(URL.init(string:)).map { Artwork(url: $0) }
        return Song(id: id, title: title, artistLine: json["artist"] as? String ?? "", album: album,
                    duration: milliseconds > 0 ? milliseconds / 1000 : nil, artwork: artwork,
                    isVideo: json["isUpload"] as? Bool ?? false, year: json["releaseYear"] as? Int)
    }

    /// One play from Android's `PlayHistoryEntry`, whose default source is YouTube.
    static func play(_ any: Any) -> Play? {
        guard let json = any as? [String: Any], (json["source"] as? String ?? "YOUTUBE") == "YOUTUBE",
              let id = json["songId"] as? String, isVideoId(id),
              let title = json["title"] as? String, let timestamp = json["timestamp"] as? Double else { return nil }
        let milliseconds = json["duration"] as? Double ?? 0
        let album = (json["albumId"] as? String).map { AlbumRef(id: $0, title: json["album"] as? String ?? "") }
        let artwork = (json["thumbnailUrl"] as? String).flatMap(URL.init(string:)).map { Artwork(url: $0) }
        let song = Song(id: id, title: title, artistLine: json["artist"] as? String ?? "", album: album,
                        duration: milliseconds > 0 ? milliseconds / 1000 : nil, artwork: artwork)
        return Play(song: song, date: Date(timeIntervalSince1970: timestamp / 1000), seconds: max(0, milliseconds / 1000))
    }

    private static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

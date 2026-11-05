import Foundation

/// Something pinned to the top of Library, as in Music: a song, an album, an artist,
/// a playlist, one of the listener's own playlists, or Liked Songs.
public enum Pin: Codable, Hashable, Sendable, Identifiable {
    case song(Song)
    case album(AlbumSummary)
    case artist(ArtistSummary)
    case playlist(PlaylistSummary)
    case userPlaylist(UUID)
    case liked

    public var id: String {
        switch self {
        case .song(let song): "s:" + song.id
        case .album(let album): "a:" + album.id
        case .artist(let artist): "r:" + artist.id
        case .playlist(let playlist): "p:" + playlist.id
        case .userPlaylist(let id): "u:" + id.uuidString
        case .liked: "liked"
        }
    }

    /// The same pin for a browse item.
    public init?(_ item: MusicItem) {
        switch item {
        case .song(let song): self = .song(song)
        case .album(let album): self = .album(album)
        case .artist(let artist): self = .artist(artist)
        case .playlist(let playlist): self = .playlist(playlist)
        }
    }

    // Equal when they pin the same thing, whatever was known about it when pinned.
    public static func == (a: Pin, b: Pin) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Decodes a value or, when it can't, nothing, so one unreadable entry doesn't sink its list.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

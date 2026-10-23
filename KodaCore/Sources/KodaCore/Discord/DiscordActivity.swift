import Foundation

/// The playing song, as much of it as a Discord card shows.
public struct DiscordNowPlaying: Equatable, Sendable {
    /// The YouTube video id.
    public var songID: String
    public var title: String
    public var artist: String
    /// The first linked artist's `UC…` channel, for a link to their page.
    public var artistChannelID: String?
    public var album: String?
    public var artwork: URL?
    /// Seconds; 0 while unknown.
    public var duration: TimeInterval
    public var position: TimeInterval
    /// The listener wants sound: true through loading and buffering, so a stall never flips the card.
    public var isPlaying: Bool

    public init(songID: String, title: String, artist: String, artistChannelID: String? = nil, album: String? = nil,
                artwork: URL? = nil, duration: TimeInterval, position: TimeInterval, isPlaying: Bool) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.artistChannelID = artistChannelID
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.position = position
        self.isPlaying = isPlaying
    }

    public init(song: Song, duration: TimeInterval, position: TimeInterval, isPlaying: Bool) {
        self.init(songID: song.id, title: song.title, artist: song.artistLine,
                  artistChannelID: song.artists.first?.id, album: song.album?.title,
                  artwork: song.artwork?.url(pixels: DiscordActivity.artworkPixels),
                  duration: duration > 0 ? duration : song.duration ?? 0, position: position, isPlaying: isPlaying)
    }
}

/// A Rich Presence activity as Discord's `SET_ACTIVITY` takes it.
///
/// The card one activity draws:
/// ```
///   Listening to Song title           <- type 2 + status_display_type 2
///   Song title                        <- details, opens the song
///   Artist                            <- state, opens the artist
///   1:04 / 3:47                       <- timestamps, while playing
///   [ Listen on YouTube Music ]
///   [ Get Koda ]
/// ```
/// Discord drops a whole activity over one field outside its limits, so every string goes
/// through `text` or `link` on the way in. Field names and limits match Koda for Android's,
/// which were checked against Discord's Social SDK; the URL fields are in Discord's own
/// `SET_ACTIVITY` example.
struct DiscordActivity: Encodable, Equatable, Sendable {
    struct Timestamps: Encodable, Equatable, Sendable {
        /// Unix seconds.
        var start: Int64
        var end: Int64
    }

    struct Assets: Encodable, Equatable, Sendable {
        var largeImage: String
        var largeText: String?
        var largeURL: String?

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image", largeText = "large_text", largeURL = "large_url"
        }
    }

    struct Button: Encodable, Equatable, Sendable {
        var label: String
        var url: String
    }

    var type = DiscordActivity.typeListening
    var statusDisplayType: Int? = DiscordActivity.statusDisplayDetails
    var details: String
    var detailsURL: String?
    var state: String?
    var stateURL: String?
    var timestamps: Timestamps?
    var assets: Assets?
    var buttons: [Button]?

    enum CodingKeys: String, CodingKey {
        case type, details, state, timestamps, assets, buttons
        case statusDisplayType = "status_display_type"
        case detailsURL = "details_url"
        case stateURL = "state_url"
    }

    static let typeListening = 2
    /// The member list reads "Listening to <details>" rather than the application's name.
    static let statusDisplayDetails = 2

    static let minText = 2
    static let maxText = 128
    static let maxURL = 256
    static let maxImage = 300
    static let maxButtonLabel = 32
    /// Discord recommends artwork of at least this many pixels a side.
    static let artworkPixels = 1024
    static let releasesURL = "https://github.com/Ivorisnoob/Koda-iOS/releases"
    /// Not whitespace, so Discord does not trim it away again.
    private static let pad: Character = "\u{2800}"

    /// The card for `song`, or nil when it has no title to show. `now` only feeds the timestamps.
    init?(_ song: DiscordNowPlaying, now: Date) {
        guard let title = Self.text(song.title) else { return nil }
        let artist = Self.text(song.artist)
        let songURL = Self.isYouTubeID(song.songID) ? Self.link("https://music.youtube.com/watch?v=\(song.songID)") : nil
        details = title
        detailsURL = songURL
        state = artist
        if artist != nil { stateURL = Self.artistURL(song) }
        if let end = Self.endTime(song, now: now) {
            timestamps = Timestamps(start: Int64((end - song.duration).rounded()), end: Int64(end.rounded()))
        }
        // Discord fetches the image itself, so only a web URL will do.
        if let image = Self.link(song.artwork?.absoluteString, limit: Self.maxImage) {
            // The album, or nothing: the title is already on the card.
            assets = Assets(largeImage: image, largeText: Self.text(song.album), largeURL: songURL)
        }
        // Buttons are plain links and can't open Koda, so the label says where the tap goes.
        var buttons: [Button] = []
        if let songURL { buttons.append(Button(label: "Listen on YouTube Music", url: songURL)) }
        buttons.append(Button(label: "Get Koda", url: Self.releasesURL))
        self.buttons = buttons
    }

    /// The same card with only the fields every Discord version has taken, for a Discord that
    /// refuses the newer ones.
    var basic: DiscordActivity {
        var card = self
        card.statusDisplayType = nil
        card.detailsURL = nil
        card.stateURL = nil
        card.assets?.largeURL = nil
        return card
    }

    /// The card without its progress bar: what it shows, apart from time passing.
    var content: DiscordActivity {
        var card = self
        card.timestamps = nil
        return card
    }

    /// When the progress bar runs out, in Unix seconds, or nil when the card has none:
    /// paused, or a length not known yet.
    static func endTime(_ song: DiscordNowPlaying, now: Date) -> TimeInterval? {
        guard song.isPlaying, song.duration > 0 else { return nil }
        // A position past the end (a last tick before the next song) never pushes the bar back.
        return now.timeIntervalSince1970 + song.duration - min(max(song.position, 0), song.duration)
    }

    /// The artist's channel when YouTube linked one; otherwise a search for the name.
    private static func artistURL(_ song: DiscordNowPlaying) -> String? {
        if let channel = song.artistChannelID, channel.hasPrefix("UC") {
            return link("https://music.youtube.com/channel/\(channel)")
        }
        // ASCII only: `alphanumerics` would let accented letters through unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let name = song.artist.trimmingCharacters(in: .whitespaces)
        guard let query = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return link("https://music.youtube.com/search?q=\(query)")
    }

    /// `value` fitted to a text field: trimmed, cut with an ellipsis when too long, padded when
    /// too short (a song called "7" is a real title, and unpadded it takes the card down).
    static func text(_ value: String?, limit: Int = maxText) -> String? {
        var text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        // Discord counts UTF-16 units; cutting by whole characters never splits an emoji.
        if text.utf16.count > limit {
            while text.utf16.count > limit - 1 { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces) + "…"
        }
        while text.count < minText { text.append(pad) }
        return text
    }

    /// `value` when it is a web link Discord will take, else nil.
    static func link(_ value: String?, limit: Int = maxURL) -> String? {
        guard let value, value.hasPrefix("https://") || value.hasPrefix("http://"), value.utf16.count <= limit else { return nil }
        return value
    }

    /// A YouTube video id: 11 base64url characters.
    static func isYouTubeID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Discord's local RPC wire: frames of an opcode and a length, both little-endian 32-bit,
/// then that many bytes of JSON.
enum DiscordIPC {
    enum Opcode: UInt32, Sendable {
        case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4
    }

    static let version = 1
    /// No reply Discord sends is near this; anything larger is a broken stream.
    static let maxPayload = 64 * 1024

    static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// The opcode and payload length from a frame's first eight bytes.
    static func header(_ bytes: Data) -> (opcode: UInt32, length: Int)? {
        guard bytes.count >= 8 else { return nil }
        let start = bytes.startIndex
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + offset + $1]) << (8 * $1) }
        }
        return (word(0), Int(word(4)))
    }

    static func handshake(clientID: String) -> Data {
        encode(Handshake(v: version, clientID: clientID))
    }

    /// `SET_ACTIVITY`; a nil activity takes the card down.
    static func setActivity(_ activity: DiscordActivity?, pid: Int32, nonce: String) -> Data {
        encode(Command(args: .init(pid: pid, activity: activity), nonce: nonce))
    }

    enum Reply: Equatable, Sendable {
        case ready
        case success(nonce: String?)
        case error(nonce: String?, message: String)
        case other
    }

    static func reply(_ payload: Data) -> Reply {
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return .other }
        let event = json["evt"] as? String
        let nonce = json["nonce"] as? String
        if event == "READY" { return .ready }
        if event == "ERROR" {
            let data = json["data"] as? [String: Any]
            let code = (data?["code"] as? NSNumber).map { " (\($0))" } ?? ""
            return .error(nonce: nonce, message: (data?["message"] as? String ?? "Unknown error") + code)
        }
        return json["cmd"] != nil ? .success(nonce: nonce) : .other
    }

    private struct Handshake: Encodable {
        var v: Int
        var clientID: String
        enum CodingKeys: String, CodingKey { case v, clientID = "client_id" }
    }

    private struct Command: Encodable {
        struct Args: Encodable {
            var pid: Int32
            var activity: DiscordActivity?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(pid, forKey: .pid)
                // Written out as null, which is how Discord is told to take the card down.
                try container.encode(activity, forKey: .activity)
            }

            enum CodingKeys: String, CodingKey { case pid, activity }
        }

        var cmd = "SET_ACTIVITY"
        var args: Args
        var nonce: String
    }

    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}

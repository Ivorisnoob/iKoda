import Foundation

/// Who a signed-in session belongs to, from YouTube Music's account menu.
public struct AccountInfo: Hashable, Codable, Sendable {
    public var name: String
    /// "@handle", when the account has a channel.
    public var handle: String?
    /// The account's own `UC…` channel, when the menu links it.
    public var channelId: String?
    public var photo: Artwork?
    /// YouTube's id for the account (`responseContext.mainAppWebResponseContext.datasyncId`),
    /// kept verbatim. The same account signed in twice has the same one, so it tells a
    /// re-sign-in from a new account.
    public var datasyncId: String?

    public init(name: String, handle: String? = nil, channelId: String? = nil, photo: Artwork? = nil, datasyncId: String? = nil) {
        self.name = name
        self.handle = handle
        self.channelId = channelId
        self.photo = photo
        self.datasyncId = datasyncId
    }
}

/// One of the account's own playlists, offered by "Add to playlist".
public struct EditablePlaylist: Identifiable, Hashable, Codable, Sendable {
    /// The playlist id without the `VL` browse prefix.
    public var id: String
    public var title: String
    /// Whether it already holds the songs asked about; nil where YouTube didn't say
    /// (music.youtube.com leaves the field out).
    public var containsSongs: Bool?

    public init(id: String, title: String, containsSongs: Bool? = nil) {
        self.id = id
        self.title = title
        self.containsSongs = containsSongs
    }
}

public enum PlaylistPrivacy: String, Codable, Sendable, CaseIterable {
    case `private` = "PRIVATE", unlisted = "UNLISTED", `public` = "PUBLIC"
}

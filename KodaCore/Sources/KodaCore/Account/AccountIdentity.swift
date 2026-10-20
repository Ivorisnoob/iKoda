import Foundation

/// Who a signed-in YouTube account is, for the account card. The name and
/// picture are YouTube's; there is nothing to edit. `datasyncId` is the
/// account's own tag and is only ever compared against another copy of it.
public struct YouTubeAccountIdentity: Hashable, Codable, Sendable {
    public var name: String
    /// The profile picture URL, asked for at a card-worthy resolution.
    public var avatarURL: URL?
    public var datasyncId: String?

    public init(name: String, avatarURL: URL? = nil, datasyncId: String? = nil) {
        self.name = name
        self.avatarURL = avatarURL
        self.datasyncId = datasyncId
    }

    /// `account/account_menu`: the popup YouTube's own account switcher opens
    /// from. The header names the account; a signed-out call answers empty.
    ///
    /// Shape as Koda for Android parses it (verified there, August 2026):
    /// `actions[0].openPopupAction.popup.multiPageMenuRenderer`, the account
    /// card under `header.activeAccountHeaderRenderer`, the name in
    /// `accountName` and the picture in the `avatar` thumbnails, and
    /// `datasyncId` free-riding in `responseContext`.
    static func parse(_ root: JSON) -> YouTubeAccountIdentity? {
        let popup = root["actions"].array.first?["openPopupAction"]["popup"]["multiPageMenuRenderer"]
        let header = popup["header"]["activeAccountHeaderRenderer"]
        let name = header["accountName"].text
        guard !name.isEmpty else { return nil }
        return YouTubeAccountIdentity(
            name: name,
            avatarURL: header["avatar"].bestThumbnail?.url(pixels: 512),
            datasyncId: root["responseContext"]["mainAppWebResponseContext"]["datasyncId"].nonEmpty)
    }
}

/// A signed-in account's own Home: the shelves it shows and the recommendations
/// in them.
public struct AccountHome: Sendable {
    /// Every shelf of the account's Home, in the order YouTube gave them.
    public var shelves: [Shelf]
    /// Quick picks: the one shelf of songs, YouTube Music's recommendations.
    public var quickPicks: [Song]
    /// The title that shelf carries, which YouTube localises.
    public var quickPicksTitle: String

    public init(shelves: [Shelf], quickPicks: [Song], quickPicksTitle: String = "Quick picks") {
        self.shelves = shelves
        self.quickPicks = quickPicks
        self.quickPicksTitle = quickPicksTitle
    }
}

/// Everything Koda reads out of one signed-in account.
public struct AccountSnapshot: Sendable {
    /// The songs the account liked on YouTube Music.
    public var liked: [Song]
    /// The playlists in the account's library.
    public var playlists: [PlaylistSummary]
    /// Who the account is, when YouTube said.
    public var identity: YouTubeAccountIdentity?

    public init(liked: [Song], playlists: [PlaylistSummary], identity: YouTubeAccountIdentity? = nil) {
        self.liked = liked
        self.playlists = playlists
        self.identity = identity
    }
}

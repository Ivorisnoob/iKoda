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
        let header = root["actions"][0]["openPopupAction"]["popup"]["multiPageMenuRenderer"]["header"]["activeAccountHeaderRenderer"]
        let name = header["accountName"].text
        guard !name.isEmpty else { return nil }
        return YouTubeAccountIdentity(
            name: name,
            avatarURL: header["avatar"].bestThumbnail?.url(pixels: 512),
            datasyncId: root["responseContext"]["mainAppWebResponseContext"]["datasyncId"].nonEmpty)
    }
}

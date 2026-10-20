import KodaCore
import SwiftUI
import UIKit

/// The listener's profile: the active one in the roster, and the picture it
/// wears.
///
/// The roster lives in `ProfileManager`; this is the app's view of it, and
/// the one place a picture is read and written.
@MainActor
@Observable
final class Profile {
    let manager: ProfileManager
    private let directory: URL
    /// The photos the listener chose, by profile.
    ///
    /// Deliberately **not** part of the observation, and deliberately a
    /// static: a view that draws a profile's picture asks for it while its
    /// body is running, and writing to something the observation watches
    /// would redraw that view for ever — the app would spin and stop
    /// answering. The picture changes only when the roster does, and that is
    /// what the views watch.
    private static let pictures = PictureStore()

    init(manager: ProfileManager, directory: URL) {
        self.manager = manager
        self.directory = directory
        Self.pictures.set(loadPhoto(manager.active), for: manager.active.id)
    }

    /// The active profile.
    var profile: KodaProfile { manager.active }
    /// The name shown for the active profile.
    var name: String { profile.displayName }
    /// The initials for a placeholder avatar.
    var initials: String { profile.initials }
    /// The photo the active profile wears, if it has one.
    var photo: UIImage? { Self.pictures.image(for: profile.id) }

    /// Read the pictures again, after a switch or a change.
    func reload() {
        Self.pictures.set(loadPhoto(profile), for: profile.id)
    }

    /// The photo a profile wears, if it has one.
    ///
    /// Reading it changes nothing the observation watches, so a view may ask
    /// for it while its body is running.
    func photo(for profile: KodaProfile) -> UIImage? {
        if let image = Self.pictures.image(for: profile.id) { return image }
        return loadPhoto(profile)
    }

    /// Read the pictures of a whole roster at once, away from any view's
    /// body: a row that draws a picture should not have to read a file
    /// every time it is drawn.
    func preparePhotos(for profiles: [KodaProfile]) {
        for profile in profiles where Self.pictures.image(for: profile.id) == nil {
            Self.pictures.set(loadPhoto(profile), for: profile.id)
        }
    }

    /// Rename the active profile.
    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.rename(profile.id, to: trimmed)
        if profile.kind == .local { manager.setLocalName(trimmed) }
    }

    /// Give the active profile a drawn avatar.
    func setDrawnAvatar(_ avatar: KodaAvatar) {
        manager.setAvatar(profile.id, avatar: avatar)
    }

    /// Store a photo, shrunk to a square 512 pixels wide.
    func setPhoto(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            Self.pictures.set(nil, for: profile.id)
            manager.setPhoto(profile.id, photo: nil)
            try? FileManager.default.removeItem(at: photoURL(profile.id))
            return
        }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: 512, height: 512)
        let squared = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = target.width / side
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        Self.pictures.set(squared, for: profile.id)
        try? squared.jpegData(compressionQuality: 0.85)?.write(to: photoURL(profile.id), options: .atomic)
        manager.setPhoto(profile.id, photo: photoURL(profile.id).lastPathComponent)
    }

    private func photoURL(_ id: UUID) -> URL {
        directory.appending(path: "avatar-\(id.uuidString).jpg")
    }

    private func loadPhoto(_ profile: KodaProfile) -> UIImage? {
        if let name = profile.photo, let image = UIImage(contentsOfFile: directory.appending(path: name).path) {
            return image
        }
        // The picture this install had before it had profiles belongs to the
        // profile on this device.
        if profile.kind == .local, let image = UIImage(contentsOfFile: directory.appending(path: "avatar.jpg").path) {
            return image
        }
        return nil
    }
}

/// A cache of pictures, deliberately kept out of the observation: reading one
/// must not change what the app knows, or a view that draws a picture would
/// redraw itself for ever.
private final class PictureStore: @unchecked Sendable {
    private var images: [UUID: UIImage] = [:]

    func image(for id: UUID) -> UIImage? { images[id] }
    func set(_ image: UIImage?, for id: UUID) { images[id] = image }
}

/// The listener's picture: the photo they chose, the drawn avatar they picked,
/// YouTube's own picture for an account, or the drawn one their id works out
/// to.
struct AvatarView: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat

    var body: some View {
        ProfileAvatar(profile: app.profile.profile, photo: app.profile.photo, size: size)
    }
}

/// A profile's picture, whatever it is made of.
struct ProfileAvatar: View {
    let profile: KodaProfile
    let photo: UIImage?
    var size: CGFloat

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            } else if let avatar = profile.avatar {
                KodaAvatarView(avatar: avatar, size: size)
            } else if let url = profile.avatarURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    KodaAvatarView(avatar: profile.effectiveAvatar, size: size)
                }
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            } else {
                KodaAvatarView(avatar: profile.effectiveAvatar, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

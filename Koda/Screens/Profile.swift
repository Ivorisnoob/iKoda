import KodaCore
import SwiftUI
import UIKit

/// The profiles' photos, read once and kept in memory, keyed by profile and photo version so a
/// new photo is never shown as the old one.
@MainActor
@Observable
final class ProfilePhotos {
    private let roster: ProfileRoster
    @ObservationIgnored private var cache: [UUID: (version: Int, image: UIImage?)] = [:]

    init(roster: ProfileRoster) {
        self.roster = roster
    }

    func photo(for profile: KodaProfile) -> UIImage? {
        if let hit = cache[profile.id], hit.version == profile.photoVersion { return hit.image }
        let image = (try? Data(contentsOf: roster.photoFile(for: profile.id))).flatMap(UIImage.init(data:))
        cache[profile.id] = (profile.photoVersion, image)
        return image
    }

    /// Store a photo for the profile, shrunk to a square 512 pixels wide; nil removes it and
    /// the profile goes back to its drawn avatar (or its account's picture).
    func setPhoto(_ data: Data?, for id: UUID) {
        guard let profile = roster.profile(id) else { return }
        let file = roster.photoFile(for: id)
        guard let data, let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: file)
            roster.update(id) {
                $0.picture = profile.accountPhoto != nil ? .account : .drawn
                $0.photoVersion += 1
            }
            return
        }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: 512, height: 512)
        let squared = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = target.width / side
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: image.size.width * scale, height: image.size.height * scale))
        }
        try? squared.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
        roster.update(id) {
            $0.picture = .photo
            $0.photoVersion += 1
        }
    }
}

/// A profile's picture: its photo, its account's picture, or its drawn avatar, which also
/// stands in while an account picture loads. An account that needs signing in again is ringed
/// in red here, so it shows from the toolbar too.
struct ProfileAvatar: View {
    let profile: KodaProfile
    var size: CGFloat
    var showsAlert = true
    @Environment(AppModel.self) private var app

    var body: some View {
        picture
            .frame(width: size, height: size)
            .overlay {
                if showsAlert, profile.isExpired {
                    Circle().strokeBorder(.red, lineWidth: max(1.5, size * 0.06))
                        .padding(-max(1.5, size * 0.06))
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        switch profile.picture {
        case .photo:
            if let image = app.profilePhotos.photo(for: profile) {
                Circle().fill(.quaternary)
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipShape(.circle)
            } else {
                KodaAvatarView(avatar: profile.avatar, size: size)
            }
        case .account:
            if let url = profile.accountPhoto {
                KodaAvatarView(avatar: profile.avatar, size: size)
                    .overlay { AccountPhoto(url: url, size: size) }
            } else {
                KodaAvatarView(avatar: profile.avatar, size: size)
            }
        case .drawn:
            KodaAvatarView(avatar: profile.avatar, size: size)
        }
    }
}

/// An account's picture from Google, faded in over the drawn avatar once it has loaded.
private struct AccountPhoto: View {
    let url: URL
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            let pixels = Int((size * scale).rounded(.up))
            let source = Artwork(url: url).url(pixels: max(pixels, 96))
            if let hit = ImagePipeline.shared.cached(source, pixels: pixels) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(source, pixels: pixels)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// The active profile's picture.
struct AvatarView: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat

    var body: some View {
        ProfileAvatar(profile: app.roster.active, size: size)
    }
}

/// The active profile's picture in a toolbar: a tap opens the profile, a long press lists the
/// other profiles to switch to, as Safari's tab groups and Mail's accounts work.
struct ProfileToolbarButton: View {
    @Environment(AppModel.self) private var app
    let open: () -> Void
    @State private var switches = 0

    var body: some View {
        Menu {
            if let back = app.quickSwitchTarget {
                Button("Switch to \(back.displayName)", systemImage: "arrow.left.arrow.right") {
                    switches += 1
                    app.switchProfile(to: back.id)
                }
            }
            Section("Switch Profile") {
                ForEach(app.roster.profiles) { profile in
                    Button {
                        guard profile.id != app.roster.activeID else { return }
                        switches += 1
                        app.switchProfile(to: profile.id)
                    } label: {
                        Label {
                            Text(profile.displayName)
                            Text(profile.subtitle)
                        } icon: {
                            Image(systemName: profile.id == app.roster.activeID ? "checkmark.circle.fill" : profile.symbol)
                        }
                    }
                }
            }
            Button("Add Profile…", systemImage: "person.badge.plus") { app.isAddingProfile = true }
        } label: {
            AvatarView(size: 32)
        } primaryAction: {
            open()
        }
        .sensoryFeedback(.selection, trigger: switches)
        .accessibilityLabel("Profile and Settings, \(app.roster.active.displayName)")
        .accessibilityHint("Touch and hold to switch profile")
    }
}

extension KodaProfile {
    /// What the profile is, in a line under its name.
    var subtitle: String {
        if isExpired { return "Sign in again" }
        switch kind {
        case .youtube: return handle ?? "YouTube Music"
        case .device: return Platform.isMac ? "On this Mac" : "On this iPhone"
        }
    }

    var symbol: String { kind == .youtube ? "person.crop.circle.badge.checkmark" : "person.crop.circle" }
}

import Foundation
import Observation

/// One person's identity in Koda: a library of their own, and optionally the YouTube Music
/// account it is signed in to.
///
/// `id` is a device-local UUID that never changes: it names the profile's folder and its
/// Keychain entry. `datasyncId` is YouTube's own account id, known once a signed-in call
/// has answered; it recognises an account already in the roster, so signing in to it again
/// repairs that profile instead of adding a second one.
public struct KodaProfile: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Only on this device; never makes a signed-in request.
        case device
        /// Signed in to a YouTube Music account.
        case youtube
    }

    /// What the profile's picture is.
    public enum Picture: String, Codable, Sendable {
        case drawn, photo, account
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    /// The account's @handle.
    public var handle: String?
    /// The account's own picture, from Google.
    public var accountPhoto: URL?
    public var datasyncId: String?
    public var avatar: KodaAvatar
    public var picture: Picture
    /// Bumped with each new photo, so an image cached under the old one isn't shown.
    public var photoVersion: Int
    public var added: Date
    /// YouTube answered this account's requests as signed out: it needs signing in again.
    public var isExpired: Bool

    public init(id: UUID = UUID(), kind: Kind, name: String, added: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        avatar = .seeded(id.uuidString)
        picture = .drawn
        photoVersion = 0
        self.added = added
        isExpired = false
    }

    public var isSignedIn: Bool { kind == .youtube }

    /// Never blank on screen.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Listener" : trimmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .device
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        accountPhoto = try c.decodeIfPresent(URL.self, forKey: .accountPhoto)
        datasyncId = try c.decodeIfPresent(String.self, forKey: .datasyncId)
        avatar = try c.decodeIfPresent(KodaAvatar.self, forKey: .avatar) ?? .seeded(id.uuidString)
        picture = try c.decodeIfPresent(Picture.self, forKey: .picture) ?? .drawn
        photoVersion = try c.decodeIfPresent(Int.self, forKey: .photoVersion) ?? 0
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        isExpired = try c.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
    }
}

/// Every profile on this device and which one is active.
///
/// Each profile owns a folder under `Profiles/<id>/` holding its library and its photo, so
/// switching is a matter of pointing the library at another folder: no network, instant,
/// offline. There is always at least one profile.
@MainActor
@Observable
public final class ProfileRoster {
    public private(set) var profiles: [KodaProfile] = []
    public private(set) var activeID: UUID
    /// The profile active before this one, for a quick switch back. In memory only: after a
    /// relaunch "back" would lead somewhere the listener didn't just come from.
    public private(set) var previousID: UUID?

    private let root: URL
    private var rosterFile: URL { root.appending(path: "profiles.json") }

    nonisolated private struct Saved: Codable {
        var profiles: [KodaProfile]
        var activeID: UUID?
    }

    /// Reads the roster under `root`, or makes the first profile there.
    ///
    /// An install from before profiles kept its library at `root/library.json`, its photo at
    /// `root/avatar.jpg` and its name in `legacyName`; they become the first profile's, so the
    /// upgrade is invisible.
    public init(root: URL, legacyName: String? = nil) {
        self.root = root
        if let data = try? Data(contentsOf: root.appending(path: "profiles.json")),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.profiles.isEmpty {
            profiles = saved.profiles
            activeID = saved.activeID.flatMap { id in saved.profiles.first { $0.id == id }?.id } ?? saved.profiles[0].id
            return
        }
        var first = KodaProfile(kind: .device, name: legacyName ?? "")
        activeID = first.id
        let folder = root.appending(path: "Profiles/\(first.id.uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = FileManager.default
        for (old, new) in [("library.json", "library.json"), ("avatar.jpg", "photo.jpg")] {
            let source = root.appending(path: old)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.moveItem(at: source, to: folder.appending(path: new))
        }
        if manager.fileExists(atPath: folder.appending(path: "photo.jpg").path) { first.picture = .photo }
        profiles = [first]
        save()
    }

    public var active: KodaProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    public func profile(_ id: UUID) -> KodaProfile? { profiles.first { $0.id == id } }

    /// Where the profile keeps its library and photo; made on first use.
    public func folder(for id: UUID) -> URL {
        let url = root.appending(path: "Profiles/\(id.uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func photoFile(for id: UUID) -> URL { folder(for: id).appending(path: "photo.jpg") }

    // MARK: Changing the roster

    @discardableResult
    public func addDeviceProfile(named name: String) -> KodaProfile {
        let profile = KodaProfile(kind: .device, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        profiles.append(profile)
        save()
        return profile
    }

    /// A signed-in account joins the roster, or, when its `datasyncId` is already here, the
    /// profile it was before is repaired instead of duplicated. `into` turns an existing
    /// profile into this account's, keeping everything it holds.
    @discardableResult
    public func addAccount(name: String, handle: String?, photo: URL?, datasyncId: String?, into existing: UUID? = nil) -> KodaProfile {
        let match = datasyncId.flatMap { id in profiles.first { $0.datasyncId == id } } ?? existing.flatMap(profile)
        var profile = match ?? KodaProfile(kind: .youtube, name: name)
        profile.kind = .youtube
        if match == nil || profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = name }
        profile.handle = handle ?? profile.handle
        profile.accountPhoto = photo ?? profile.accountPhoto
        profile.datasyncId = datasyncId ?? profile.datasyncId
        if profile.picture == .drawn, profile.accountPhoto != nil { profile.picture = .account }
        profile.isExpired = false
        upsert(profile)
        return profile
    }

    public func update(_ id: UUID, _ change: (inout KodaProfile) -> Void) {
        guard var profile = profile(id) else { return }
        change(&profile)
        guard profile != self.profile(id) else { return }
        upsert(profile)
    }

    /// The account is let go; the profile stays on this device with everything it holds.
    public func signOut(_ id: UUID) {
        update(id) { profile in
            profile.kind = .device
            profile.handle = nil
            profile.datasyncId = nil
            profile.isExpired = false
            if profile.picture == .account { profile.picture = .drawn }
            profile.accountPhoto = nil
        }
    }

    /// Delete a profile and everything it keeps on this device. The last profile can't be
    /// deleted; deleting the active one makes another active (`switchTo` tells the app which).
    @discardableResult
    public func delete(_ id: UUID, switchTo: (UUID) -> Void) -> Bool {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return false }
        if activeID == id, let next = profiles.first(where: { $0.id != id }) {
            switchTo(next.id)
            activeID = next.id
        }
        profiles.removeAll { $0.id == id }
        if previousID == id || previousID == activeID { previousID = nil }
        save()
        try? FileManager.default.removeItem(at: root.appending(path: "Profiles/\(id.uuidString)"))
        return true
    }

    /// Make `id` the active profile. The app moves its library and session over first.
    public func setActive(_ id: UUID) {
        guard id != activeID, profile(id) != nil else { return }
        previousID = activeID
        activeID = id
        save()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = profiles
        let moving = source.sorted().map { list[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { list.remove(at: index) }
        list.insert(contentsOf: moving, at: min(max(insertAt, 0), list.count))
        profiles = list
        save()
    }

    private func upsert(_ profile: KodaProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    /// Small and rare: written at once, so a switch is on disk before anything reads it.
    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(profiles: profiles, activeID: activeID)) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: rosterFile, options: .atomic)
    }
}

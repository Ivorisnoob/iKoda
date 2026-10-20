import Foundation
import Observation

/// One of Koda's profiles: who the app is being right now.
///
/// A profile is either **local** — a face on this device, with no Google
/// account behind it — or a **YouTube** account, whose session signs Koda's
/// requests. The local profile always exists, so the roster is never empty
/// and there is always somewhere to be when an account is signed out.
///
/// Everything a listener builds up — their likes, their history, their
/// playlists — belongs to the profile that made it. Switching profiles
/// therefore changes what the app *is*, not merely what it is signed in as.
public struct KodaProfile: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// On this device only: no Google account.
        case local
        /// A Google account, whose session signs Koda's requests.
        case youtube
    }

    public let id: UUID
    public var kind: Kind
    /// The name shown in the roster: the listener's own for a local profile,
    /// the account's name for a YouTube one.
    public var name: String
    /// The picture YouTube gave the account, when there is one.
    public var avatarURL: String?
    /// YouTube's own account id, the thing that recognises an account already
    /// in the roster. Nil until the first signed-in answer carries it.
    public var datasyncId: String?
    /// The drawn avatar, when the listener chose one. Nil means nobody chose:
    /// a profile on this device wears the one its id works out to, and an
    /// account wears YouTube's own picture.
    public var avatar: KodaAvatar?
    /// The photo the listener chose, as a file name in the app's directory.
    public var photo: String?
    /// When the profile joined the roster.
    public var created: Date
    /// The last time the profile was used; the roster is ordered by it.
    public var lastUsed: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        avatarURL: String? = nil,
        datasyncId: String? = nil,
        avatar: KodaAvatar? = nil,
        photo: String? = nil,
        created: Date = Date(),
        lastUsed: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.avatarURL = avatarURL
        self.datasyncId = datasyncId
        self.avatar = avatar
        self.photo = photo
        self.created = created
        self.lastUsed = lastUsed
    }

    /// The drawn avatar a profile wears when nobody chose one: the same every
    /// time for the same id.
    public var effectiveAvatar: KodaAvatar {
        avatar ?? KodaAvatar.forSeed(id.uuidString)
    }

    /// The name to show, with a stand-in for a profile that has none.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind == .local ? "On This Device" : "YouTube Music"
    }

    /// A short line saying what the profile is.
    public var subtitle: String {
        switch kind {
        case .local: "On this device"
        case .youtube: "YouTube Music account"
        }
    }

    /// The initials for a placeholder avatar.
    public var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "K" : letters
    }
}

/// The roster of profiles and the one that is active.
@MainActor
@Observable
public final class ProfileManager {
    /// Every profile, the active one first.
    public private(set) var profiles: [KodaProfile] = []
    /// The profile the app is being right now.
    public private(set) var activeID: UUID
    /// Bumped whenever the active profile changes, or a profile joins or
    /// leaves. Anything that fetched something for a profile checks it
    /// afterwards, so a late answer cannot land in the wrong profile.
    public private(set) var generation = 0

    private let file: URL?
    private var defaults: UserDefaults

    /// - Parameter directory: where the roster is kept.
    /// - Parameter defaults: where the local profile's name and choices are kept.
    public init(directory: URL?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        file = directory?.appending(path: "profiles.json")
        let loaded: Roster? = file.flatMap { url -> Roster? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Roster.self, from: data)
        }
        if let loaded, !loaded.profiles.isEmpty {
            profiles = loaded.profiles
            activeID = loaded.active
        } else {
            // The first launch: the local profile, carrying the name and photo
            // this install already had.
            let local = KodaProfile(kind: .local, name: defaults.string(forKey: Keys.localName) ?? "")
            profiles = [local]
            activeID = local.id
        }
        if !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles[0].id
        }
    }

    private enum Keys {
        static let localName = "koda.profile.name"
    }

    private struct Roster: Codable {
        var profiles: [KodaProfile] = []
        var active: UUID
    }

    // MARK: Reading

    /// The profile the app is being right now.
    public var active: KodaProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    /// The profile with a given id.
    public func profile(_ id: UUID) -> KodaProfile? {
        profiles.first { $0.id == id }
    }

    /// The profiles, the active one first.
    public var roster: [KodaProfile] {
        var ordered = profiles.sorted { $0.lastUsed > $1.lastUsed }
        if let index = ordered.firstIndex(where: { $0.id == activeID }) {
            let active = ordered.remove(at: index)
            ordered.insert(active, at: 0)
        }
        return ordered
    }

    // MARK: Switching

    /// Make a profile the active one.
    ///
    /// The switch itself is one write: everything that needs the session asks
    /// the account store for it as it goes, so nothing has to be rebuilt.
    /// The generation moves, and anything that was fetching for the profile
    /// that was left will find the generation changed and drop its answer.
    public func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id
        profiles = profiles.map { profile in
            var profile = profile
            if profile.id == id { profile.lastUsed = Date() }
            return profile
        }
        generation += 1
        save()
    }

    // MARK: The roster

    /// Add a profile to the roster, without making it active.
    @discardableResult
    public func add(_ profile: KodaProfile) -> KodaProfile {
        profiles.append(profile)
        generation += 1
        save()
        return profile
    }

    /// Add another profile on this device, with no account behind it.
    @discardableResult
    public func addLocal(name: String = "") -> KodaProfile {
        let profile = KodaProfile(kind: .local, name: name)
        profiles.append(profile)
        generation += 1
        save()
        return profile
    }

    /// Change a profile.
    public func update(_ profile: KodaProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    /// Rename a profile.
    public func rename(_ id: UUID, to name: String) {
        guard var profile = profile(id) else { return }
        profile.name = name
        update(profile)
    }

    /// Give a profile a drawn avatar.
    public func setAvatar(_ id: UUID, avatar: KodaAvatar) {
        guard var profile = profile(id) else { return }
        profile.avatar = avatar
        update(profile)
    }

    /// Give a profile a photo, or take it away.
    public func setPhoto(_ id: UUID, photo: String?) {
        guard var profile = profile(id) else { return }
        profile.photo = photo
        update(profile)
    }

    /// Remove a profile from the roster. Its data stays where it is, on this
    /// device, unreachable; the id is never reissued, so a restored backup
    /// cannot land on it.
    public func remove(_ id: UUID) {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id {
            activeID = profiles[0].id
            generation += 1
        }
        generation += 1
        save()
    }

    /// The local profile's name, kept where it always was, so an install that
    /// already had one keeps it.
    public func setLocalName(_ name: String) {
        defaults.set(name, forKey: Keys.localName)
    }

    // MARK: Storage

    /// The roster as it is kept on disk, for a backup to carry.
    public func rosterData() -> Data? {
        guard let file else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Take a roster from a backup. The profiles come back; the sessions do
    /// not, so an account is signed into again on this device.
    public func restoreRoster(from data: Data) {
        guard let restored = try? JSONDecoder().decode(Roster.self, from: data),
              !restored.profiles.isEmpty else { return }
        profiles = restored.profiles
        // The profile that was active stays the active one if it is still
        // here; otherwise the first one is.
        if !profiles.contains(where: { $0.id == activeID }) {
            activeID = restored.profiles[0].id
        }
        generation += 1
        save()
    }

    private func save() {
        guard let file else { return }
        let roster = Roster(profiles: profiles, active: activeID)
        guard let data = try? JSONEncoder().encode(roster) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

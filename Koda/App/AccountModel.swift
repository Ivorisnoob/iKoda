import KodaCore
import SwiftUI

/// The signed-in YouTube Music account of this install: the live session, who
/// it is, and the account's own library mirrored into Koda.
///
/// The session itself lives in `AccountStore` (KodaCore), which holds the
/// cookies in the Keychain and keeps them fresh. This is the app's view of
/// it: what the settings show, the sync that reads the account's liked songs
/// and playlists, and the switching between profiles.
///
/// **Every answer is bound to the profile it was asked for.** A sync that was
/// started for one profile and lands after the listener has switched is
/// dropped, not written into the profile that is active now. The generation
/// is what says so.
@MainActor
@Observable
final class AccountModel {
    /// What the session can do right now.
    enum Status: Equatable {
        /// No account on this device.
        case signedOut
        /// An account is signed in and YouTube is accepting it.
        case connected
        /// An account is signed in, but YouTube has refused the session.
        case expired

        var title: String {
            switch self {
            case .signedOut: "Not Connected"
            case .connected: "Connected"
            case .expired: "Needs Sign-In"
            }
        }
    }

    /// How long a synced account's library stays fresh before it is read again.
    static let syncInterval: TimeInterval = 6 * 60 * 60

    let store: AccountStore
    private let music: YouTubeMusic
    private let library: Library
    private let profiles: ProfileManager

    /// A sync is running.
    private(set) var isSyncing = false
    /// The last sync's problem, when there was one.
    private(set) var error: String?
    /// The YouTube profiles with no session on this device: they need signing
    /// in again before they can be used.
    private(set) var needsSignIn: Set<UUID> = []
    /// Bumped whenever the account context changes: a switch, a sign-in, a
    /// sign-out. Anything that fetched for the account checks it afterwards.
    private(set) var generation = 0

    init(store: AccountStore, music: YouTubeMusic, library: Library, profiles: ProfileManager) {
        self.store = store
        self.music = music
        self.library = library
        self.profiles = profiles
        updateNeedsSignIn()
    }

    /// Look again at which profiles have a session. The Keychain is asked
    /// once per profile, and the answer kept, so the roster is not read over
    /// and over while it is drawn.
    func updateNeedsSignIn() {
        var missing: Set<UUID> = []
        for profile in profiles.profiles where profile.kind == .youtube {
            if !store.hasSession(for: profile.id) { missing.insert(profile.id) }
        }
        needsSignIn = missing
    }

    // MARK: What the settings read

    /// An account is attached to this device.
    var isSignedIn: Bool { store.isConnected }
    /// What the session can do right now.
    var status: Status {
        guard store.isConnected else { return .signedOut }
        return store.isExpired ? .expired : .connected
    }
    /// The profile the app is being right now.
    var profile: KodaProfile { profiles.active }
    /// The roster, the active profile first.
    var roster: [KodaProfile] { profiles.roster }
    /// Who the account is, as YouTube last said.
    var name: String { profiles.active.displayName }
    /// The account's picture, when it has one.
    var avatarURL: URL? { profiles.active.avatarURL.flatMap(URL.init(string:)) }
    /// When the account's library was last read.
    var lastSynced: Date? { library.accountSyncedAt }

    // MARK: Switching

    /// Make another profile the active one.
    ///
    /// The session, the library and the pages built for the old profile all
    /// move together. Switching costs no network and works offline: the
    /// session is already on the device.
    func activate(_ id: UUID) {
        guard id != profiles.activeID else { return }
        // The profile has to be in the roster: pointing the session and the
        // library at a profile that is not there would leave both empty.
        guard profiles.profiles.contains(where: { $0.id == id }) else { return }
        profiles.activate(id)
        store.activate(profileID: id)
        library.activate(id)
        generation += 1
        error = nil
        Task { await music.clearPageCache() }
    }

    /// Remove a profile from the roster. The profile that was active becomes
    /// another one, with its own session and its own library.
    func remove(_ id: UUID) {
        let wasActive = profiles.activeID == id
        profiles.remove(id)
        store.forget(profileID: id)
        if wasActive {
            let next = profiles.activeID
            store.activate(profileID: next)
            library.activate(next)
            generation += 1
            error = nil
            Task { await music.clearPageCache() }
        }
        updateNeedsSignIn()
    }

    // MARK: Signing in and out

    /// Take a session from the login capture and give it to the roster.
    ///
    /// The account joins the roster as a profile of its own. If YouTube says
    /// it is an account already here, that profile is repaired instead of a
    /// second one being added. [verified on Koda for Android, August 2026]
    func signIn(cookieHeader: String) async {
        guard store.isComplete(cookieHeader) else {
            error = "That session is not complete enough to sign in with."
            return
        }
        error = nil
        let previous = profiles.active
        let stamp = generation

        // The account joins the roster first, so the session has somewhere to
        // live while YouTube is asked who it is.
        var candidate = KodaProfile(kind: .youtube, name: "")
        profiles.add(candidate)
        store.activate(profileID: candidate.id)
        store.signIn(cookieHeader: cookieHeader)

        let identity = try? await music.accountIdentity()
        // The listener may have switched profiles while YouTube was answering:
        // this sign-in belongs to the profile that was active when it began.
        guard stamp == generation else {
            // The half-made profile goes with it: a row with no name and no
            // account id is worse than no row.
            store.forget(profileID: candidate.id)
            profiles.remove(candidate.id)
            updateNeedsSignIn()
            return
        }
        let datasyncId = identity?.datasyncId
        if let datasyncId, let existing = profiles.profiles.first(where: { $0.datasyncId == datasyncId && $0.id != candidate.id }) {
            // An account already in the roster: the session goes to that
            // profile, and the row that was just added is taken away.
            store.activate(profileID: existing.id)
            store.signIn(cookieHeader: cookieHeader)
            var repaired = existing
            repaired.name = identity?.name ?? repaired.name
            repaired.avatarURL = identity?.avatarURL?.absoluteString ?? repaired.avatarURL
            repaired.datasyncId = datasyncId
            repaired.lastUsed = Date()
            profiles.update(repaired)
            store.forget(profileID: candidate.id)
            profiles.remove(candidate.id)
            candidate = repaired
        } else {
            candidate.name = identity?.name ?? "YouTube Music"
            candidate.avatarURL = identity?.avatarURL?.absoluteString
            candidate.datasyncId = datasyncId
            profiles.update(candidate)
        }

        profiles.activate(candidate.id)
        store.activate(profileID: candidate.id)
        // Signing in from a profile on this device must not take its library
        // away: the new profile starts with a copy of it.
        if previous.kind == .local, previous.id != candidate.id {
            library.copyLibrary(from: previous.id, to: candidate.id)
        }
        library.activate(candidate.id)
        generation += 1
        updateNeedsSignIn()

        await music.clearPageCache()
        await sync(force: true)
    }

    /// Sign out: forget the session of the active profile. The profile keeps
    /// its place in the roster, and its library, and can be signed into again.
    func signOut() {
        store.signOut()
        library.clearAccountData()
        error = nil
        generation += 1
        updateNeedsSignIn()
        Task { await music.clearPageCache() }
    }

    // MARK: Syncing

    /// Read the account's library into Koda: the songs it liked and the
    /// playlists in it. Nothing of the listener's own is touched.
    func sync(force: Bool = false) async {
        guard store.isConnected, !isSyncing else { return }
        if !force, let last = library.accountSyncedAt,
           Date().timeIntervalSince(last) < Self.syncInterval { return }
        isSyncing = true
        error = nil
        let stamp = generation
        defer { isSyncing = false }

        let snapshot = await music.accountSnapshot()
        // The listener may have switched profiles while this was in the air:
        // the answer belongs to the profile it was asked for, not to the one
        // that is active now.
        guard stamp == generation else { return }
        if store.isExpired {
            // YouTube refused the session: what came back is signed-out
            // content, and it must not be written over the account's library.
            error = "Your YouTube session expired. Sign in again to keep syncing."
            return
        }
        if let identity = snapshot.identity {
            var profile = profiles.active
            profile.name = identity.name
            profile.avatarURL = identity.avatarURL?.absoluteString ?? profile.avatarURL
            profile.datasyncId = identity.datasyncId ?? profile.datasyncId
            profiles.update(profile)
        }
        library.applyAccountSync(liked: snapshot.liked,
                                 playlists: snapshot.playlists,
                                 name: snapshot.identity?.name ?? profiles.active.displayName)
    }

    /// Read the account's library when it has gone stale, so a listener who
    /// has not opened Koda for a while still sees what their account holds.
    func syncIfNeeded() async {
        await sync(force: false)
    }

    /// Who the account is, asked of YouTube rather than remembered.
    func refreshIdentity() async {
        guard store.isConnected else { return }
        let stamp = generation
        guard let identity = try? await music.accountIdentity() else { return }
        guard stamp == generation else { return }
        var profile = profiles.active
        profile.name = identity.name
        profile.avatarURL = identity.avatarURL?.absoluteString ?? profile.avatarURL
        profile.datasyncId = identity.datasyncId ?? profile.datasyncId
        profiles.update(profile)
    }
}

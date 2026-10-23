import Foundation

/// A profile's YouTube sign-in as the app hands it over.
public struct AccountSession: Sendable, Hashable {
    public var profileID: UUID
    public var cookies: YouTubeCookies

    public init(profileID: UUID, cookies: YouTubeCookies) {
        self.profileID = profileID
        self.cookies = cookies
    }
}

/// Where cookies Google rotates mid-session are kept: `AccountKeychain` in the app.
public protocol AccountCookieStore: Sendable {
    func save(_ cookies: YouTubeCookies, for profileID: UUID)
}

/// YouTube's word on a profile's session, from a response to a request signed with it.
public struct AccountVerdict: Sendable, Hashable {
    public var profileID: UUID
    /// False once YouTube answered a signed request as anonymous: the session is over
    /// and only signing in again brings it back. True again if a later answer says so.
    public var signedIn: Bool
}

/// What one request went out with, so its response is credited to that sign-in even
/// when the active profile has changed since.
struct AccountTicket: Sendable {
    let profileID: UUID
    let generation: Int
    let cookies: YouTubeCookies
}

/// The session `YouTubeMusic` signs requests with, and the bookkeeping that follows them.
///
/// One sign-in is a *generation*: signing in again starts a new one, while Google
/// rotating a cookie keeps it. Rotated cookies from a response are folded into the
/// profile its request was made for and written to the store, whichever profile is
/// active by then; a response for a sign-in that has since ended (forgotten, or
/// signed in afresh) writes nothing anywhere.
///
/// The only verdict on a session is YouTube's own `logged_in` in a response's
/// `responseContext`. HTTP 200 proves nothing (a dead session reads public pages fine),
/// and cookies are never dropped over one bad answer: a later rotation can revive them.
public actor AccountSessions {
    private struct Entry {
        var generation: Int
        var cookies: YouTubeCookies
        var signedIn: Bool?
    }

    private var entries: [UUID: Entry] = [:]
    private var activeID: UUID?
    private var generations = 0
    private let store: (any AccountCookieStore)?
    private let continuation: AsyncStream<AccountVerdict>.Continuation

    /// Each change in a profile's verdict, for one listener (the app's roster).
    public nonisolated let verdicts: AsyncStream<AccountVerdict>

    public init(store: (any AccountCookieStore)? = nil) {
        self.store = store
        (verdicts, continuation) = AsyncStream.makeStream(of: AccountVerdict.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Sign requests as `session`'s profile, as on launch or a switch. If this run has
    /// already seen the profile, the cookies it holds are kept: they include rotations
    /// the app's copy may predate. A profile seen for the first time takes `session`'s.
    public func activate(_ session: AccountSession) {
        if entries[session.profileID] == nil {
            entries[session.profileID] = Entry(generation: nextGeneration(), cookies: session.cookies)
        }
        activeID = session.profileID
    }

    /// A fresh sign-in for the profile: replaces whatever it had, writes it to the store,
    /// and makes it active. Responses to requests from before it no longer count.
    public func signIn(_ session: AccountSession) {
        entries[session.profileID] = Entry(generation: nextGeneration(), cookies: session.cookies)
        store?.save(session.cookies, for: session.profileID)
        activeID = session.profileID
    }

    /// Send requests signed out, for a profile on this device only.
    public func deactivate() {
        activeID = nil
    }

    /// The profile signed out or was removed: nothing more is written for it, not even
    /// by requests still in flight. Deleting its stored cookies is the caller's.
    public func forget(_ profileID: UUID) {
        entries[profileID] = nil
        if activeID == profileID { activeID = nil }
    }

    /// The session requests are signed with now, cookies as of the latest rotation.
    public var active: AccountSession? {
        guard let activeID, let entry = entries[activeID] else { return nil }
        return AccountSession(profileID: activeID, cookies: entry.cookies)
    }

    /// The profile's newest cookies this run, rotations included.
    public func cookies(for profileID: UUID) -> YouTubeCookies? {
        entries[profileID]?.cookies
    }

    /// The last verdict this run for the profile, nil before any signed answer.
    public func signedIn(_ profileID: UUID) -> Bool? {
        entries[profileID]?.signedIn
    }

    // MARK: Requests

    func ticket() -> AccountTicket? {
        guard let activeID, let entry = entries[activeID] else { return nil }
        return AccountTicket(profileID: activeID, generation: entry.generation, cookies: entry.cookies)
    }

    /// What the page cache is keyed by, so one profile's signed-in pages are never
    /// served to another (or to the same profile signed in afresh).
    var cacheScope: String {
        guard let activeID, let entry = entries[activeID] else { return "" }
        return "\(activeID.uuidString)#\(entry.generation)"
    }

    /// Fold a response's `Set-Cookie` headers into the cookies of the sign-in `ticket`
    /// was issued for.
    func received(setCookie headers: [String], for ticket: AccountTicket, now: Date = Date()) {
        guard !headers.isEmpty, var entry = entries[ticket.profileID], entry.generation == ticket.generation else { return }
        let merged = entry.cookies.merging(SetCookie.parse(headers, now: now), sent: ticket.cookies)
        guard merged != entry.cookies else { return }
        entry.cookies = merged
        entries[ticket.profileID] = entry
        store?.save(merged, for: ticket.profileID)
    }

    /// Record YouTube's verdict on the sign-in `ticket` was issued for.
    func note(signedIn: Bool, for ticket: AccountTicket) {
        guard var entry = entries[ticket.profileID], entry.generation == ticket.generation, entry.signedIn != signedIn else { return }
        entry.signedIn = signedIn
        entries[ticket.profileID] = entry
        continuation.yield(AccountVerdict(profileID: ticket.profileID, signedIn: signedIn))
    }

    private func nextGeneration() -> Int {
        generations += 1
        return generations
    }
}

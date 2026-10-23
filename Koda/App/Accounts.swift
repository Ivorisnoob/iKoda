import Foundation
import KodaCore

/// Profiles' YouTube Music accounts: which session signs requests, signing in and out,
/// YouTube's verdicts on sessions, and keeping a profile's library in step with its account.
///
/// Switching itself is local and instant (`switchProfile`); what follows here runs behind it.
/// Session changes and writes go through `accountWork` one at a time, and each write checks the
/// session it would go out under is still its profile's, so nothing is ever sent as the wrong
/// account. Reading the account's library runs on its own and is thrown away if the listener
/// switched while it ran.
extension AppModel {
    /// At launch: the active profile's session, YouTube's verdicts, and the listener's own likes
    /// and saves going to their account.
    func connectAccounts() {
        library.onChange = { [weak self] change in self?.send(change) }
        let scrobble = player.onItemHeard
        player.onItemHeard = { [weak self] item, seconds in
            scrobble?(item, seconds)
            self?.heardForHistory(item, seconds)
        }
        let watched = videos.onWatch
        videos.onWatch = { [weak self] video in
            watched?(video)
            // Each watch is its own play in the account's history.
            self?.videoHistory = nil
        }
        videos.onWatchSpan = { [weak self] id, start, end, final in
            self?.watchedForHistory(id, from: start, to: end, final: final)
        }
        let verdicts = music.accounts.verdicts
        Task { [weak self] in
            for await verdict in verdicts { self?.apply(verdict) }
        }
        let active = roster.active
        enqueueAccountWork { [self] in await activateSession(for: active) }
        syncAccount()
    }

    /// Back on screen: a session the locked Keychain kept back, and a sync if the last is old.
    func accountsBecameActive() {
        if needsSessionRead {
            needsSessionRead = false
            let active = roster.active
            enqueueAccountWork { [self] in await activateSession(for: active) }
        }
        syncAccount()
    }

    /// Requests follow the profile switched to: its session, or none for a device profile, and a
    /// new visitor identity whenever an account is on either side.
    func moveSession(from leaving: KodaProfile, to profile: KodaProfile) {
        enqueueAccountWork { [self] in
            await activateSession(for: profile)
            if leaving.isSignedIn || profile.isSignedIn { await music.renewVisitorIdentity() }
        }
        stopSync()
        syncAccount(force: true)
    }

    // MARK: Signing in and out

    enum SignInError: LocalizedError {
        case noSession

        var errorDescription: String? {
            switch self {
            case .noSession: "Google didn't finish signing in to YouTube Music. Try again."
            }
        }
    }

    /// The sign-in page has youtube.com's cookies. YouTube is asked who they belong to before the
    /// roster changes: a known account (by `datasyncId`) repairs its profile, `into` signs that
    /// profile in keeping what it holds, and otherwise the account becomes a profile of its own.
    /// The app then switches to it and brings its library in.
    func completeSignIn(cookies httpCookies: [HTTPCookie], into: UUID?) async throws {
        let cookies = YouTubeCookies(httpCookies)
        guard cookies.looksSignedIn else { throw SignInError.noSession }
        let trial = into ?? UUID()
        let profileID: UUID = try await withAccountWork { [self] in
            await music.accounts.signIn(AccountSession(profileID: trial, cookies: cookies))
            let info: AccountInfo
            do {
                info = try await music.accountInfo()
            } catch {
                await music.accounts.forget(trial)
                keychain.delete(trial)
                await activateSession(for: roster.active)
                throw error
            }
            let profile = roster.addAccount(name: info.name, handle: info.handle, photo: info.photo?.url,
                                            datasyncId: info.datasyncId, into: into)
            if profile.id != trial {
                // Known already under another profile: the session moves there, rotations included.
                let latest = await music.accounts.cookies(for: trial) ?? cookies
                await music.accounts.forget(trial)
                keychain.delete(trial)
                await music.accounts.signIn(AccountSession(profileID: profile.id, cookies: latest))
            }
            return profile.id
        }
        if profileID != roster.activeID {
            switchProfile(to: profileID)
        } else {
            // Signed in where the listener already was: the session is live, the identity changes.
            enqueueAccountWork { [self] in await music.renewVisitorIdentity() }
            syncAccount(force: true)
        }
    }

    /// The account is let go; the profile stays on this device with everything it holds.
    func signOut(_ id: UUID) {
        let wasActive = id == roster.activeID
        roster.signOut(id)
        forgetAccount(of: id)
        try? FileManager.default.removeItem(at: mirrorFile(id))
        guard wasActive else { return }
        stopSync()
        enqueueAccountWork { [self] in await music.renewVisitorIdentity() }
    }

    /// Nothing more is sent or saved for the profile's account.
    func forgetAccount(of id: UUID) {
        keychain.delete(id)
        mirrors[id] = nil
        lastAccountSync[id] = nil
        enqueueAccountWork { [self] in await music.accounts.forget(id) }
    }

    // MARK: Quick switch

    /// Where a quick switch goes: the profile used before this one, or with exactly two, the other.
    var quickSwitchTarget: KodaProfile? {
        if let previous = roster.previousID, previous != roster.activeID, let profile = roster.profile(previous) { return profile }
        guard roster.profiles.count == 2 else { return nil }
        return roster.profiles.first { $0.id != roster.activeID }
    }

    // MARK: Library sync

    /// Bring the active profile's library in step with its account: unsent changes go first, then
    /// what the account holds comes in and what was removed from it goes. At most every 15
    /// minutes unless forced (sign-in, switch, pull to refresh).
    func syncAccount(force: Bool = false) {
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired else { return }
        if !force, let last = lastAccountSync[profile.id], Date().timeIntervalSince(last) < 15 * 60 { return }
        let id = profile.id
        lastAccountSync[id] = Date()
        syncTask?.cancel()
        syncRound += 1
        let round = syncRound
        syncTask = Task { [self] in
            await sendPending(for: id)
            guard !Task.isCancelled, roster.activeID == id else { return }
            isSyncingAccount = true
            defer { if syncRound == round { isSyncingAccount = false } }
            do {
                async let liked = music.likedSongs()
                async let albums = music.libraryAlbums()
                async let playlists = music.libraryPlaylists()
                async let artists = music.libraryArtists()
                let account = try await AccountLibrary(liked: liked, albums: albums, playlists: playlists, artists: artists)
                let info = try? await music.accountInfo()
                // Switched away (or away and back) while it read: these pages may not all be this account's.
                guard !Task.isCancelled, roster.activeID == id else { return }
                let before = mirror(id)
                let firstSync = before.liked.isEmpty && before.albums.isEmpty && before.playlists.isEmpty && before.artists.isEmpty
                updateMirror(id) { library.reconcile(with: account, mirror: &$0) }
                // Home was made before the account's likes arrived, so Your Mix had nothing to seed from.
                if firstSync, home.profile == id { Task { await loadHome(home) } }
                if let info {
                    roster.update(id) {
                        $0.handle = info.handle ?? $0.handle
                        $0.accountPhoto = info.photo?.url ?? $0.accountPhoto
                        $0.datasyncId = info.datasyncId ?? $0.datasyncId
                    }
                }
            } catch MusicError.signedOut {
                roster.update(id) { $0.isExpired = true }
            } catch {
                // Offline or refused for now: the next chance tries again.
                lastAccountSync[id] = nil
            }
        }
    }

    /// Load Home once the session has settled, so a Home made by a switch or a sign-in is asked
    /// for as the right account (or as none), not the one being left.
    func loadHome(_ model: HomeModel) async {
        await accountWork?.value
        await model.load(music: music, library: library, signedIn: roster.profile(model.profile)?.isSignedIn == true)
    }

    /// A sync now, for pull to refresh, finishing when it does.
    func refreshAccount() async {
        syncAccount(force: true)
        await syncTask?.value
    }

    private func stopSync() {
        syncTask?.cancel()
        syncRound += 1
        isSyncingAccount = false
    }

    /// A like or save the listener made: remembered until the account has it, and sent now.
    private func send(_ change: LibraryChange) {
        let profile = roster.active
        guard profile.isSignedIn else { return }
        let id = profile.id
        updateMirror(id) { $0.queue(change) }
        guard !profile.isExpired else { return }
        enqueueAccountWork { [self] in
            guard await music.accounts.active?.profileID == id else { return }
            if await write(change, for: id) { updateMirror(id) { $0.sent(change) } }
        }
    }

    /// Changes made offline or before a sign-in expired, oldest first; stops at the first that
    /// has to wait, so they reach the account in the order they were made.
    private func sendPending(for id: UUID) async {
        try? await withAccountWork { [self] in
            guard await music.accounts.active?.profileID == id else { return }
            for change in mirror(id).pending {
                guard await write(change, for: id) else { break }
                updateMirror(id) { $0.sent(change) }
            }
        }
    }

    /// Sends one change; false when it should wait and go again later. A change YouTube turns
    /// down outright counts as done, or it would block every change behind it.
    private func write(_ change: LibraryChange, for id: UUID) async -> Bool {
        do {
            switch change {
            case .liked(let song, let on):
                try await music.setLiked(videoId: song.id, liked: on)
            case .playlist(let playlist, let on):
                try await music.setSaved(playlistId: playlist.id, saved: on)
            case .artist(let artist, let on):
                try await music.setSubscribed(channelId: artist.id, subscribed: on)
            case .album(let album, let on):
                // Albums are saved by their audio playlist, not their MPRE id.
                guard let playlist = try await music.album(album.id).audioPlaylistId else { return true }
                try await music.setSaved(playlistId: playlist, saved: on)
            }
            return true
        } catch MusicError.signedOut {
            roster.update(id) { $0.isExpired = true }
            return false
        } catch let error as MusicError where error == .network || error == .rateLimited {
            return false
        } catch is CancellationError {
            return false
        } catch {
            return true
        }
    }

    // MARK: Subscriptions and ratings

    /// Subscribe to a channel, or unsubscribe, as the active account; false if it didn't go.
    /// Every page showing the channel follows (`subscriptions`).
    func setSubscribed(_ channelId: String, _ on: Bool) async -> Bool {
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired else { return false }
        let id = profile.id
        let sent = (try? await withAccountWork { [self] () async throws -> Bool in
            guard await music.accounts.active?.profileID == id else { return false }
            do {
                try await music.setSubscribed(channelId: channelId, subscribed: on)
                return true
            } catch MusicError.signedOut {
                roster.update(id) { $0.isExpired = true }
                return false
            }
        }) ?? false
        if sent, roster.activeID == id { subscriptions[channelId] = on }
        return sent
    }

    /// Whether the active account follows a channel: a change made here this run, else what
    /// the page said (nil when it didn't say).
    func isSubscribed(_ channelId: String, page: Bool?) -> Bool? {
        subscriptions[channelId] ?? page
    }

    /// Like, dislike or clear the rating of a video as the active account; false if it didn't go.
    func rate(_ videoId: String, _ status: LikeStatus) async -> Bool {
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired else { return false }
        let id = profile.id
        let sent = (try? await withAccountWork { [self] () async throws -> Bool in
            guard await music.accounts.active?.profileID == id else { return false }
            do {
                try await music.rate(videoId: videoId, status)
                return true
            } catch MusicError.signedOut {
                roster.update(id) { $0.isExpired = true }
                return false
            }
        }) ?? false
        if sent, roster.activeID == id { videoRatings[videoId] = status }
        return sent
    }

    // MARK: YouTube history for videos

    /// A span of a video watched: the first files the video in the account's YouTube history
    /// (Android's VideoWatchTracker), the rest say how far it got. Same switches as songs.
    private func watchedForHistory(_ videoId: String, from start: TimeInterval, to end: TimeInterval, final: Bool) {
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired, profile.sendsPlaysToYouTube, settings.savesListeningHistory else { return }
        let id = profile.id
        enqueueAccountWork { [self] in
            guard await music.accounts.active?.profileID == id else { return }
            do {
                if videoHistory?.session.videoId != videoId || videoHistory?.profile != id {
                    videoHistory = (try await music.beginVideoHistory(videoId: videoId, at: start), id)
                }
                guard let session = videoHistory?.session else { return }
                try await music.reportVideoWatchtime(session, from: start, to: end, final: final)
            } catch MusicError.signedOut {
                roster.update(id) { $0.isExpired = true }
                videoHistory = nil
            } catch {
                // Best effort, as for songs: a missed ping isn't retried.
            }
        }
    }

    // MARK: YouTube history

    /// A play heard for 15 seconds goes to the account's YouTube history, if the profile wants
    /// that and listening history isn't paused (a pause keeps everything from leaving, as it
    /// does for Last.fm and Discord).
    private func heardForHistory(_ item: QueueItem, _ seconds: TimeInterval) {
        guard historyThreshold.add(seconds, to: item.id, duration: item.song.duration) else { return }
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired, profile.sendsPlaysToYouTube, settings.savesListeningHistory else { return }
        let id = profile.id
        let videoId = item.song.id
        enqueueAccountWork { [self] in
            guard await music.accounts.active?.profileID == id else { return }
            do {
                try await music.reportPlayback(videoId: videoId)
            } catch MusicError.signedOut {
                roster.update(id) { $0.isExpired = true }
            } catch {
                // A play that couldn't be filed isn't retried: history is a record of now.
            }
        }
    }

    // MARK: Sessions

    /// Sign requests as `profile`'s account, or signed out for a device profile. A YouTube profile
    /// with nothing saved needs signing in again; one the locked Keychain won't read yet goes
    /// signed out until the app is next active, without being called signed out.
    private func activateSession(for profile: KodaProfile) async {
        guard profile.isSignedIn else {
            await music.accounts.deactivate()
            return
        }
        switch keychain.read(profile.id) {
        case .found(let cookies):
            await music.accounts.activate(AccountSession(profileID: profile.id, cookies: cookies))
        case .missing:
            await music.accounts.deactivate()
            roster.update(profile.id) { $0.isExpired = true }
        case .unreadable:
            await music.accounts.deactivate()
            needsSessionRead = true
        }
    }

    /// YouTube's word on a session marks its profile as needing sign-in, or clears that again.
    private func apply(_ verdict: AccountVerdict) {
        guard roster.profile(verdict.profileID)?.isSignedIn == true else { return }
        roster.update(verdict.profileID) { $0.isExpired = !verdict.signedIn }
    }

    private func enqueueAccountWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = accountWork
        accountWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Runs `work` in its turn among the session changes and writes, and hands back its result.
    private func withAccountWork<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = accountWork
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        accountWork = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: The account mirror

    private func mirrorFile(_ id: UUID) -> URL {
        roster.folder(for: id).appending(path: "account.json")
    }

    private func mirror(_ id: UUID) -> AccountMirror {
        if let cached = mirrors[id] { return cached }
        let loaded = (try? Data(contentsOf: mirrorFile(id))).flatMap { try? JSONDecoder().decode(AccountMirror.self, from: $0) } ?? AccountMirror()
        mirrors[id] = loaded
        return loaded
    }

    private func updateMirror(_ id: UUID, _ change: (inout AccountMirror) -> Void) {
        var value = mirror(id)
        let before = value
        change(&value)
        guard value != before else { return }
        mirrors[id] = value
        let file = mirrorFile(id)
        let saved = value
        // Off the main thread, and in order, so an older state never lands after a newer one.
        AccountMirrorWriter.queue.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

nonisolated enum AccountMirrorWriter {
    static let queue = DispatchQueue(label: "ivors.Koda.account-mirror", qos: .utility)
}

import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite struct AccountMirrorTests {
    let a = Song(id: "a", title: "A", artistLine: "X")
    let b = Song(id: "b", title: "B", artistLine: "X")
    let c = Song(id: "c", title: "C", artistLine: "X")

    @Test func theFirstSyncBringsTheAccountInAndKeepsWhatIsOnlyHere() {
        let library = Library(directory: nil)
        library.toggleLike(c)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["a", "b", "c"])
        #expect(mirror.liked == ["a", "b"])
    }

    @Test func somethingRemovedOnTheAccountLeavesHereToo() {
        let library = Library(directory: nil)
        library.toggleLike(c)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b], albums: [AlbumSummary(id: "MPRE1", title: "Al", artistLine: "X")]), mirror: &mirror)
        // Unliked and unsaved on another device.
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["a", "c"])
        #expect(library.albums.isEmpty)
    }

    @Test func anUnlikeNotYetSentIsntLikedAgain() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        library.toggleLike(a)
        mirror.queue(.liked(a, false))
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["b"])
    }

    @Test func aLikeNotYetSentIsntDropped() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        // Unliked elsewhere, then liked again here while offline.
        mirror.queue(.liked(b, true))
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        #expect(library.isLiked(b))
    }

    @Test func aNewerChangeReplacesTheOlderOne() {
        var mirror = AccountMirror()
        mirror.queue(.liked(a, true))
        mirror.queue(.liked(b, true))
        mirror.queue(.liked(a, false))
        #expect(mirror.pending == [.liked(b, true), .liked(a, false)])
        // An older send finishing doesn't clear the newer change.
        mirror.sent(.liked(a, true))
        #expect(mirror.pending == [.liked(b, true), .liked(a, false)])
        mirror.sent(.liked(a, false))
        #expect(mirror.pending == [.liked(b, true)])
    }

    // Issue #12: songs unliked here came back on the next refresh, because YouTube's liked list
    // still held them for a while after the unlike went through.
    @Test func aSentUnlikeIsntUndoneByAListThatHasntCaughtUp() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        let start = Date()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror, at: start)
        library.toggleLike(a)
        mirror.queue(.liked(a, false))
        mirror.sent(.liked(a, false), at: start)
        #expect(mirror.pending.isEmpty)
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror, at: start + 60)
        #expect(library.liked.map(\.id) == ["b"])
        // The list catches up: the change has settled and the song stays gone.
        library.reconcile(with: AccountLibrary(liked: [b]), mirror: &mirror, at: start + 120)
        #expect(mirror.settling.isEmpty)
        #expect(library.liked.map(\.id) == ["b"])
    }

    @Test func aSentLikeIsntDroppedByAListThatHasntCaughtUp() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        let start = Date()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror, at: start)
        // Unliked elsewhere and liked again here; the read still shows the other device's unlike.
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror, at: start)
        library.toggleLike(b)
        mirror.queue(.liked(b, true))
        mirror.sent(.liked(b, true), at: start)
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror, at: start + 60)
        #expect(library.isLiked(b))
    }

    @Test func theAccountsWordStandsOnceTheChangeHasHadTimeToSettle() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        let start = Date()
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror, at: start)
        library.toggleLike(a)
        mirror.queue(.liked(a, false))
        mirror.sent(.liked(a, false), at: start)
        // Still liked on the account an hour on: it didn't keep the unlike.
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror, at: start + AccountMirror.settleTime + 1)
        #expect(mirror.settling.isEmpty)
        #expect(library.isLiked(a))
    }

    @Test func aNewChangeReplacesOneStillSettling() {
        var mirror = AccountMirror()
        mirror.queue(.liked(a, false))
        mirror.sent(.liked(a, false))
        mirror.queue(.liked(a, true))
        #expect(mirror.settling.isEmpty)
        #expect(mirror.pending == [.liked(a, true)])
    }

    @Test func survivesARoundTrip() throws {
        var mirror = AccountMirror()
        mirror.liked = ["a"]
        mirror.queue(.liked(b, false))
        mirror.sent(.liked(b, false), at: Date(timeIntervalSince1970: 1_000_000))
        mirror.queue(.album(AlbumSummary(id: "MPRE1", title: "Al", artistLine: "X"), true))
        let data = try JSONEncoder().encode(mirror)
        #expect(try JSONDecoder().decode(AccountMirror.self, from: data) == mirror)
        #expect(try JSONDecoder().decode(AccountMirror.self, from: Data("{}".utf8)) == AccountMirror())
    }

    @Test func mergingDoesNotTellOnChange() {
        let library = Library(directory: nil)
        var told: [LibraryChange] = []
        library.onChange = { told.append($0) }
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        library.reconcile(with: AccountLibrary(), mirror: &mirror)
        #expect(told.isEmpty)
        library.toggleLike(b)
        #expect(told == [.liked(b, true)])
    }
}


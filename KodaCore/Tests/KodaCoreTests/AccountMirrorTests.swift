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

    @Test func survivesARoundTrip() throws {
        var mirror = AccountMirror()
        mirror.liked = ["a"]
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


import Foundation
import Testing
@testable import KodaCore

/// The roster of profiles, and what each of them keeps.
@MainActor
@Suite struct ProfileTests {
    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "koda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeManager() throws -> ProfileManager {
        let defaults = try #require(UserDefaults(suiteName: "ivors.Koda.tests.\(UUID().uuidString)"))
        return ProfileManager(directory: try tempDirectory(), defaults: defaults)
    }

    @Test func theRosterAlwaysHasTheProfileOnThisDevice() throws {
        let manager = try makeManager()
        #expect(manager.profiles.count == 1)
        #expect(manager.active.kind == .local)
        #expect(manager.activeID == manager.profiles[0].id)
    }

    @Test func theRosterSurvivesARelaunch() throws {
        let directory = try tempDirectory()
        let defaults = try #require(UserDefaults(suiteName: "ivors.Koda.tests.\(UUID().uuidString)"))
        let manager = ProfileManager(directory: directory, defaults: defaults)
        let account = manager.add(KodaProfile(kind: .youtube, name: "Ivor"))
        manager.activate(account.id)

        let again = ProfileManager(directory: directory, defaults: defaults)
        #expect(again.profiles.count == 2)
        #expect(again.activeID == account.id)
        #expect(again.active.name == "Ivor")
    }

    @Test func switchingMovesTheActiveProfileAndTheGeneration() throws {
        let manager = try makeManager()
        let local = manager.activeID
        let account = manager.add(KodaProfile(kind: .youtube, name: "Ivor"))
        let generation = manager.generation

        manager.activate(account.id)
        #expect(manager.activeID == account.id)
        #expect(manager.generation > generation, "anything fetching for a profile can tell it was left")

        // Switching to the profile that is already active changes nothing.
        let still = manager.generation
        manager.activate(account.id)
        #expect(manager.generation == still)

        manager.activate(local)
        #expect(manager.activeID == local)
    }

    @Test func removingAProfileLeavesTheRestAlone() throws {
        let manager = try makeManager()
        let account = manager.add(KodaProfile(kind: .youtube, name: "Ivor"))
        manager.remove(account.id)
        #expect(manager.profiles.count == 1)
        #expect(manager.active.kind == .local)
    }

    @Test func theLastProfileIsNeverRemoved() throws {
        let manager = try makeManager()
        manager.remove(manager.activeID)
        #expect(manager.profiles.count == 1)
    }

    @Test func anAvatarIsTheSameEveryTimeAndReadsBack() throws {
        let first = KodaAvatar.forSeed("ivor")
        let second = KodaAvatar.forSeed("ivor")
        #expect(first == second, "the same id always draws the same face")
        #expect(KodaAvatar.forSeed("someone-else") != first)
        #expect(KodaAvatar.decode(first.encoded) == first)
        #expect(KodaAvatar.decode("nonsense") == nil)
        // An index past the end of a set still draws.
        let wrapped = KodaAvatar(shape: 99, color: 99, eyes: 99, mouth: 99, extra: 99, blush: false)
        #expect(KodaAvatarColours.colour(wrapped.color) == KodaAvatarColours.colour(99 % KodaAvatarColours.all.count))
    }

    @Test func eachProfileKeepsItsOwnLibrary() throws {
        let directory = try tempDirectory()
        let first = UUID()
        let second = UUID()
        let library = Library(directory: directory, profileID: first)
        library.toggleLike(Song(id: "a", title: "A", artistLine: "X"))
        #expect(library.liked.count == 1)

        library.activate(second)
        #expect(library.liked.isEmpty, "the other profile has liked nothing")
        library.toggleLike(Song(id: "b", title: "B", artistLine: "Y"))

        library.activate(first)
        #expect(library.liked.map(\.id) == ["a"], "the first profile keeps what it liked")

        library.activate(second)
        #expect(library.liked.map(\.id) == ["b"])
    }

    @Test func aNewProfileStartsWithACopyOfTheOldOne() throws {
        let directory = try tempDirectory()
        let local = UUID()
        let account = UUID()
        let library = Library(directory: directory, profileID: local)
        library.toggleLike(Song(id: "a", title: "A", artistLine: "X"))

        library.copyLibrary(from: local, to: account)
        library.activate(account)
        #expect(library.liked.map(\.id) == ["a"], "signing in takes nothing away")
    }

    @Test func theRosterTravelsWithTheBackup() throws {
        let directory = try tempDirectory()
        let defaults = try #require(UserDefaults(suiteName: "ivors.Koda.tests.\(UUID().uuidString)"))
        let manager = ProfileManager(directory: directory, defaults: defaults)
        manager.add(KodaProfile(kind: .youtube, name: "Ivor"))
        let library = Library(directory: directory, profileID: manager.activeID)

        let data = try #require(library.backupData(roster: manager.rosterData()))
        let roster = try #require(Library.roster(in: data))

        let elsewhere = ProfileManager(directory: try tempDirectory(),
                                      defaults: try #require(UserDefaults(suiteName: "ivors.Koda.tests.\(UUID().uuidString)")))
        elsewhere.restoreRoster(from: roster)
        #expect(elsewhere.profiles.count == 2, "the profiles come back with the library")
        #expect(elsewhere.profiles.contains { $0.name == "Ivor" })
    }
}

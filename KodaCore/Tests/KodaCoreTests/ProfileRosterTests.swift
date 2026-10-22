import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite struct ProfileRosterTests {
    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "koda-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anInstallFromBeforeProfilesBecomesTheFirstProfile() throws {
        let root = try tempDirectory()
        try Data(#"{"liked":[{"id":"a","title":"A","artistLine":"X","artists":[],"isVideo":false}]}"#.utf8)
            .write(to: root.appending(path: "library.json"))
        try Data([0xFF, 0xD8]).write(to: root.appending(path: "avatar.jpg"))

        let roster = ProfileRoster(root: root, legacyName: "Sam")
        #expect(roster.profiles.count == 1)
        #expect(roster.active.name == "Sam")
        #expect(roster.active.kind == .device)
        #expect(roster.active.picture == .photo)
        let library = Library(directory: roster.folder(for: roster.activeID))
        #expect(library.liked.map(\.id) == ["a"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "library.json").path))

        // A second launch reads the roster rather than making another first profile.
        let again = ProfileRoster(root: root, legacyName: "Sam")
        #expect(again.profiles.map(\.id) == roster.profiles.map(\.id))
    }

    @Test func switchingRemembersWhereItCameFromAndPersists() throws {
        let root = try tempDirectory()
        let roster = ProfileRoster(root: root)
        let first = roster.activeID
        let second = roster.addDeviceProfile(named: " Guest ")
        #expect(second.name == "Guest")
        roster.setActive(second.id)
        #expect(roster.previousID == first)
        #expect(ProfileRoster(root: root).activeID == second.id)
    }

    @Test func anAccountAlreadyHereIsRepairedNotDuplicated() throws {
        let roster = ProfileRoster(root: try tempDirectory())
        let account = roster.addAccount(name: "Sam", handle: "@sam", photo: URL(string: "https://example.com/a.jpg"), datasyncId: "D1")
        roster.update(account.id) { $0.isExpired = true }
        let again = roster.addAccount(name: "Sam S", handle: nil, photo: nil, datasyncId: "D1")
        #expect(again.id == account.id)
        #expect(roster.profiles.count == 2)
        #expect(again.isExpired == false)
        #expect(again.handle == "@sam")
        #expect(again.picture == .account)
    }

    @Test func signingInAProfileKeepsItAndSigningOutKeepsItToo() throws {
        let roster = ProfileRoster(root: try tempDirectory(), legacyName: "Me")
        let id = roster.activeID
        let signedIn = roster.addAccount(name: "Google Name", handle: "@me", photo: nil, datasyncId: "D2", into: id)
        #expect(signedIn.id == id)
        #expect(signedIn.name == "Me", "a name the listener chose stays")
        #expect(roster.profiles.count == 1)
        roster.signOut(id)
        #expect(roster.active.kind == .device)
        #expect(roster.active.datasyncId == nil)
    }

    @Test func theLastProfileStaysAndDeletingTheActiveOneSwitches() throws {
        let root = try tempDirectory()
        let roster = ProfileRoster(root: root)
        let first = roster.activeID
        #expect(!roster.delete(first) { _ in })
        let second = roster.addDeviceProfile(named: "B")
        let folder = roster.folder(for: first)
        var switched: UUID?
        #expect(roster.delete(first) { switched = $0 })
        #expect(switched == second.id)
        #expect(roster.profiles.map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func readsAProfileSavedWithFewerFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old"}"#
        let profile = try JSONDecoder().decode(KodaProfile.self, from: Data(json.utf8))
        #expect(profile.kind == .device)
        #expect(profile.picture == .drawn)
        #expect(profile.avatar == KodaAvatar.seeded(id.uuidString))
    }
}

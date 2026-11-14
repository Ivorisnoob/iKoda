import Foundation
import Testing
@testable import KodaCore

struct AppReleaseTests {
    @Test func versionsCompareNumberByNumber() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("0.10") > v("0.9"))
        #expect(try v("v0.4") == v("0.4"))
        #expect(try v("1.0") == v("1"))
        #expect(try v("1.0.1") > v("1"))
        #expect(try v("0.4") < v("0.4.1"))
        #expect(try v("2.0-beta") == v("2.0"))
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("") == nil)
        #expect(try Set([v("1.0"), v("1")]).count == 1)
    }

    /// A real `releases/latest` answer from GitHub (Koda 0.3).
    @Test func readsGitHubsLatestRelease() throws {
        let url = try #require(Bundle.module.url(forResource: "github-release-latest", withExtension: "json", subdirectory: "Fixtures"))
        let release = try #require(AppRelease(gitHub: Data(contentsOf: url)))
        #expect(release.version == AppVersion("0.3"))
        #expect(release.title == "Koda 0.3")
        #expect(release.page.absoluteString == "https://github.com/Ivorisnoob/iKoda/releases/tag/v0.3")
        #expect(release.dmg?.url.lastPathComponent == "Koda.dmg")
        #expect(release.dmg?.size == 11_937_334)
        #expect(release.ipa?.url.lastPathComponent == "Koda.ipa")
        #expect(release.notes.hasPrefix("Koda 0.3 brings AutoMix"))
        #expect(!release.notes.contains("\r"))
        #expect(release.published != nil)
    }

    @Test func leavesOutDraftsAndPreReleases() {
        let pre = #"{"tag_name":"v9.0","html_url":"https://github.com/a/b","prerelease":true}"#
        let draft = #"{"tag_name":"v9.0","html_url":"https://github.com/a/b","draft":true}"#
        let plain = #"{"tag_name":"v9.0","html_url":"https://github.com/a/b"}"#
        #expect(AppRelease(gitHub: Data(pre.utf8)) == nil)
        #expect(AppRelease(gitHub: Data(draft.utf8)) == nil)
        #expect(AppRelease(gitHub: Data(plain.utf8))?.title == "Koda 9.0")
    }

    @Test func checksOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdatePolicy().isDue(at: now))
        #expect(!UpdatePolicy(lastCheck: now.addingTimeInterval(-3600)).isDue(at: now))
        #expect(UpdatePolicy(lastCheck: now.addingTimeInterval(-UpdatePolicy.checkInterval)).isDue(at: now))
        #expect(UpdatePolicy(lastCheck: now.addingTimeInterval(3600)).isDue(at: now))
    }

    @Test func offersOnlyWhatTheListenerHasntPutOff() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let release = AppRelease(version: try #require(AppVersion("0.5")), title: "Koda 0.5", notes: "",
                                 page: URL(string: "https://github.com")!, published: nil, dmg: nil, ipa: nil)
        let current = try #require(AppVersion("0.4"))
        #expect(UpdatePolicy().shouldOffer(release, over: current, at: now, asked: false))
        // Nothing newer than what runs.
        #expect(!UpdatePolicy().shouldOffer(release, over: try #require(AppVersion("0.5")), at: now, asked: true))
        // Skipped: quiet, until a newer one or the listener asks.
        let skipped = UpdatePolicy(skipped: AppVersion("0.5"))
        #expect(!skipped.shouldOffer(release, over: current, at: now, asked: false))
        #expect(skipped.shouldOffer(release, over: current, at: now, asked: true))
        #expect(UpdatePolicy(skipped: AppVersion("0.4.9")).shouldOffer(release, over: current, at: now, asked: false))
        // Remind me later: quiet until it runs out.
        let later = UpdatePolicy(remindAfter: now.addingTimeInterval(7 * 86_400))
        #expect(!later.shouldOffer(release, over: current, at: now, asked: false))
        #expect(later.shouldOffer(release, over: current, at: now.addingTimeInterval(8 * 86_400), asked: false))
    }
}

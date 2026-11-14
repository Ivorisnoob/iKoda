import KodaCore
import SwiftUI

/// Looks for new releases of Koda on GitHub and decides when to bring one up: on its own once a
/// day (`UpdatePolicy`), never a version the listener skipped, not again before a "remind me
/// later" runs out, and always when asked. The Mac installs what it finds (MacUpdater.swift);
/// the iPhone, which can't install apps itself, only says so (UpdateNoticeView).
@MainActor
@Observable
final class UpdateCenter {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// Bytes received of the total, which is nil while the server hasn't said.
        case downloading(AppRelease, received: Int64, total: Int64?)
        case installing(AppRelease)
        case failed(String)
    }

    /// What the update window or notice shows.
    var phase: Phase = .idle
    /// A release to bring up now: the Mac opens its update window, the iPhone its notice.
    var offered: AppRelease?
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }
    private(set) var lastCheck: Date?

    let current: AppVersion
    @ObservationIgnored private var policy: UpdatePolicy
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored var installing: Task<Void, Never>?
    /// Runs before the Mac quits to put the new version in place: the app saves what it holds.
    @ObservationIgnored var beforeRelaunch: (() -> Void)?

    /// The repository Koda is released from.
    static let releases = URL(string: "https://github.com/Ivorisnoob/iKoda/releases")!
    private static let feed = URL(string: "https://api.github.com/repos/Ivorisnoob/iKoda/releases/latest")!

    private enum Keys {
        static let automatic = "koda.updates.automatic"
        static let lastCheck = "koda.updates.lastCheck"
        static let skipped = "koda.updates.skipped"
        static let remindAfter = "koda.updates.remindAfter"
    }

    init() {
        let defaults = UserDefaults.standard
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        current = AppVersion(short) ?? AppVersion("0")!
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        let last = defaults.object(forKey: Keys.lastCheck) as? Date
        lastCheck = last
        policy = UpdatePolicy(lastCheck: last,
                              skipped: defaults.string(forKey: Keys.skipped).flatMap(AppVersion.init),
                              remindAfter: defaults.object(forKey: Keys.remindAfter) as? Date)
    }

    /// Checks now if a day has passed, then looks again every hour whether another has.
    func start() {
        guard checking == nil else { return }
        checking = Task { [weak self] in
            // Not in the way of the app's own first requests at launch.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                if self.checksAutomatically, self.policy.isDue(at: .now) { await self.check(asked: false) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// `asked`: the listener chose Check for Updates, so the answer is shown whatever it is and
    /// a skipped or postponed version is offered again.
    func check(asked: Bool) async {
        switch phase {
        case .downloading, .installing, .checking: return
        default: break
        }
        if asked { phase = .checking }
        do {
            let release = try await Self.latest()
            let now = Date()
            lastCheck = now
            policy.lastCheck = now
            UserDefaults.standard.set(now, forKey: Keys.lastCheck)
            if let release, policy.shouldOffer(release, over: current, at: now, asked: asked) {
                phase = .available(release)
                offered = release
            } else {
                phase = asked ? .upToDate : .idle
            }
        } catch {
            // A check made on its own fails quietly and is tried again next hour.
            phase = asked ? .failed("Koda couldn't reach GitHub to check for updates. Check your connection and try again.") : .idle
        }
    }

    /// Not this version: it's left alone until a newer one comes out.
    func skip(_ release: AppRelease) {
        policy.skipped = release.version
        UserDefaults.standard.set(release.version.description, forKey: Keys.skipped)
        dismiss()
    }

    /// Asked about again once `days` have passed.
    func remindLater(_ release: AppRelease, days: Int) {
        let date = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        policy.remindAfter = date
        UserDefaults.standard.set(date, forKey: Keys.remindAfter)
        dismiss()
    }

    func dismiss() {
        offered = nil
        switch phase {
        case .downloading, .installing: break
        default: phase = .idle
        }
    }

    private static func latest() async throws -> AppRelease? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Koda", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // No release published yet.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return AppRelease(gitHub: data)
    }
}

extension AppRelease: @retroactive Identifiable {
    public var id: String { version.description }
}

/// A release's notes as written on GitHub: headings, bullet points and paragraphs, with bold,
/// italics, code and links inside them. SwiftUI's own Markdown reads only the inline parts.
struct ReleaseNotesView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else if line.hasPrefix("#") {
                endParagraph()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                endParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(Self.inline(text))
                        .font(.scaled(.headline))
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                    .font(.scaled(.callout))
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .font(.scaled(.callout))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

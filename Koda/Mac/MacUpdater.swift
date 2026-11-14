#if os(macOS)
import AppKit
import KodaCore
import SwiftUI

// Koda updating itself on the Mac, as Sparkle-updated apps do: the new release's disk image is
// downloaded with its progress shown, opened out of sight, and its Koda checked (this app's
// bundle id, the version the release promised, a signature that verifies); then Koda quits and
// a small helper puts the new copy where this one was and opens it. Downloaded by the app
// itself, the new copy carries no quarantine, so macOS doesn't ask about it again.

extension UpdateCenter {
    /// Why Koda can't replace itself where it is, or nil when it can.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") {
            return "Koda is running from the disk image or a temporary place. Move Koda to your Applications folder, open it from there, then update."
        }
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder), FileManager.default.isWritableFile(atPath: app.path) else {
            return "Koda can't replace itself in \(folder). Download the new version from GitHub and drag it to Applications."
        }
        return nil
    }

    func install(_ release: AppRelease) {
        guard installing == nil else { return }
        installing = Task { await performInstall(release) }
    }

    func cancelInstall() {
        installing?.cancel()
        installing = nil
        if let release = offered { phase = .available(release) } else { phase = .idle }
    }

    private func performInstall(_ release: AppRelease) async {
        defer { installing = nil }
        guard let dmg = release.dmg else {
            phase = .failed("This release has no Mac download. Get it from GitHub instead.")
            return
        }
        if let blocker = installBlocker {
            phase = .failed(blocker)
            return
        }
        phase = .downloading(release, received: 0, total: dmg.size > 0 ? Int64(dmg.size) : nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "KodaUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = try await DiskImageDownload.fetch(dmg.url, to: folder.appending(path: "Koda.dmg")) { [weak self] received, total in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(release, received: received, total: total ?? (dmg.size > 0 ? Int64(dmg.size) : nil))
                }
            }
            try Task.checkCancellation()
            phase = .installing(release)
            let destination = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? "ivors.Koda"
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.stage(diskImage: file, version: release.version, bundleID: bundleID, beside: destination)
            }.value
            try? FileManager.default.removeItem(at: folder)
            try Task.checkCancellation()
            beforeRelaunch?()
            try Self.replaceAndRelaunch(destination: destination, with: staged)
            NSApplication.shared.terminate(nil)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed((error as? UpdateError)?.message ?? "The update couldn't be downloaded. Check your connection and try again.")
        }
    }

    nonisolated struct UpdateError: Error {
        let message: String
    }

    /// Opens the disk image out of sight, checks the Koda in it and copies it next to this one,
    /// on the same volume, so putting it in place is a rename.
    private nonisolated static func stage(diskImage: URL, version: AppVersion, bundleID: String, beside destination: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appending(path: "KodaUpdateMount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            throw UpdateError(message: "The downloaded disk image couldn't be opened. Try again.")
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) else {
            throw UpdateError(message: "The download doesn't hold Koda. Try again later.")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID,
              let short = info["CFBundleShortVersionString"] as? String, AppVersion(short) == version else {
            throw UpdateError(message: "The download isn't the Koda \(version) it should be, so it wasn't installed.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            throw UpdateError(message: "The new Koda's signature doesn't check out, so it wasn't installed.")
        }
        let staged = destination.deletingLastPathComponent().appending(path: ".Koda-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [app.path, staged.path]) else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError(message: "The new Koda couldn't be copied next to this one.")
        }
        return staged
    }

    /// Starts the helper that waits for Koda to quit, swaps the new copy in (putting the old back
    /// if that fails) and opens it. It outlives the app: a quitting app doesn't take its children.
    private static func replaceAndRelaunch(destination: URL, with staged: URL) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"
        for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        old="$target.old-$$"
        if mv "$target" "$old"; then
            if mv "$staged" "$target"; then rm -rf "$old"; else mv "$old" "$target"; fi
        fi
        rm -rf "$staged"
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        open "$target"
        """
        let helper = FileManager.default.temporaryDirectory.appending(path: "koda-update-\(UUID().uuidString).sh")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), destination.path, staged.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// One download with its progress, which the async `URLSession` calls don't report.
private nonisolated final class DiskImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let download = DiskImageDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.withLock { download.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The file is gone once this returns, so it moves now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - The window

/// Koda → Check for Updates…, as every Mac app has it under About.
struct CheckForUpdatesButton: View {
    let updates: UpdateCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            openWindow(id: SoftwareUpdateView.windowID)
            Task { await updates.check(asked: true) }
        }
    }
}

/// The Software Update window: what's new and the choice to install it, the download's
/// progress, or the answer to a check that was asked for.
struct SoftwareUpdateView: View {
    static let windowID = "softwareUpdate"
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    private var updates: UpdateCenter { app.updates }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image("KodaIcon")
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        // Open with nothing under way: look, rather than show a check that isn't happening.
        .task {
            if updates.phase == .idle { await updates.check(asked: true) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            VStack(alignment: .leading, spacing: 14) {
                Text("Checking for Updates…").font(.scaled(.headline))
                ProgressView().progressViewStyle(.linear)
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                }
            }
        case .upToDate:
            message("You're up to date!", "Koda \(updates.current) is the newest version available.")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("Update Failed").font(.scaled(.headline))
                Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Open Releases on GitHub", destination: UpdateCenter.releases)
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { Task { await updates.check(asked: true) } }.keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
            }
        case .available(let release):
            offer(release) {
                Button("Skip This Version") { updates.skip(release); close() }
                Spacer()
                Button("Remind Me Later") { updates.remindLater(release, days: 1); close() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updates.install(release) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let received, let total):
            offer(release) {
                VStack(alignment: .leading, spacing: 6) {
                    if let total, total > 0 {
                        ProgressView(value: Double(received), total: Double(total))
                        Text("Downloading… \(Self.bytes(received)) of \(Self.bytes(total))")
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Downloading… \(Self.bytes(received))")
                    }
                }
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Button("Cancel") { updates.cancelInstall() }.keyboardShortcut(.cancelAction)
            }
        case .installing(let release):
            offer(release) {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear)
                    Text("Installing… Koda will reopen in a moment.")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A release on offer: its name, what you have, its notes, and the row of choices under them.
    private func offer(_ release: AppRelease, @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A new version of Koda is available!").font(.scaled(.headline))
            Text("\(release.title) is now available. You have \(updates.current). Would you like to install it now?")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Release Notes:")
                .font(.scaled(.subheadline).weight(.semibold))
                .padding(.top, 10)
            ScrollView {
                ReleaseNotesView(markdown: release.notes.isEmpty ? "No notes for this release." : release.notes)
                    .padding(12)
            }
            .frame(height: 260)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(alignment: .center, spacing: 12) {
                actions()
            }
            .padding(.top, 12)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.scaled(.headline))
            Text(detail).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
    }

    private func close() {
        updates.dismiss()
        dismissWindow(id: Self.windowID)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
#endif

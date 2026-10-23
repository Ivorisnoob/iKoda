import KodaCore
import SwiftUI

/// How far a download has come, as a ring that fills.
struct DownloadProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
        }
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// A song row's mark: downloaded, or on its way.
struct DownloadIndicator: View {
    let song: Song
    @Environment(Downloads.self) private var downloads

    var body: some View {
        switch downloads.state(of: song) {
        case .none:
            EmptyView()
        case .waiting:
            Image(systemName: "arrow.down.circle.dotted")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Waiting to download")
        case .downloading(let progress):
            DownloadProgressRing(progress: progress)
                .frame(width: 13, height: 13)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// The toolbar button of an album or playlist: download it all, see it come, or remove it.
struct DownloadButton: View {
    let songs: [Song]
    /// The whole collection when `songs` is only what has loaded so far, as a long playlist's is.
    var allSongs: (@MainActor () async -> [Song])?
    @Environment(Downloads.self) private var downloads
    @State private var confirmsRemoval = false
    @State private var started = 0

    var body: some View {
        let state = downloads.state(of: songs)
        Button {
            switch state {
            case .none:
                started += 1
                downloads.download(songs)
                if let allSongs {
                    Task { downloads.download(await allSongs()) }
                }
            case .waiting, .downloading, .downloaded:
                confirmsRemoval = true
            }
        } label: {
            switch state {
            case .none:
                Label("Download", systemImage: "arrow.down.circle")
            case .waiting, .downloading:
                DownloadProgressRing(progress: progress(state), lineWidth: 2.5)
                    .frame(width: 20, height: 20)
            case .downloaded:
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
            }
        }
        .disabled(songs.isEmpty)
        .sensoryFeedback(.start, trigger: started)
        .confirmationDialog(state == .downloaded ? "Remove these downloads?" : "Stop downloading?",
                            isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button(state == .downloaded ? "Remove Downloads" : "Stop and Remove", role: .destructive) {
                downloads.remove(songs)
            }
        } message: {
            Text("They'll play from YouTube again, which needs a connection.")
        }
        .accessibilityLabel(label(state))
    }

    private func progress(_ state: Downloads.State) -> Double {
        if case .downloading(let progress) = state { return progress }
        return 0
    }

    private func label(_ state: Downloads.State) -> String {
        switch state {
        case .none: "Download"
        case .waiting, .downloading: "Downloading"
        case .downloaded: "Downloaded"
        }
    }
}

/// Download or remove one song, for its menu.
struct DownloadMenuItem: View {
    let song: Song
    @Environment(Downloads.self) private var downloads

    var body: some View {
        switch downloads.state(of: song) {
        case .none:
            Button("Download", systemImage: "arrow.down.circle") { downloads.download([song]) }
        case .waiting, .downloading:
            Button("Stop Download", systemImage: "xmark.circle") { downloads.remove([song]) }
        case .downloaded:
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove([song]) }
        }
    }
}

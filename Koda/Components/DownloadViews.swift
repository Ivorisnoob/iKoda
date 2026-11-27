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
                .font(.scaled(.footnote))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Waiting to download")
        case .downloading(let progress):
            DownloadProgressRing(progress: progress)
                .frame(width: 13, height: 13)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.scaled(.footnote))
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
    @State private var finished = 0

    var body: some View {
        let state = downloads.state(of: songs)
        let coming = state == .waiting || isDownloading(state)
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
            // One arrow all along: it gives way to a ring with a stop square while the songs
            // come, and comes back filled, with a bounce, once they're all here.
            Label {
                Text(label(state))
            } icon: {
                Image(systemName: state == .downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: finished)
                    .opacity(coming ? 0 : 1)
                    .overlay {
                        if coming {
                            DownloadProgressRing(progress: progress(state), lineWidth: 2.5)
                                .overlay {
                                    Image(systemName: "stop.fill")
                                        .font(.scaledSystem(size: 7, weight: .black))
                                        .foregroundStyle(.tint)
                                }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
            }
        }
        .animation(.smooth(duration: 0.3), value: coming)
        .onChange(of: state == .downloaded) { _, done in if done { finished += 1 } }
        .disabled(songs.isEmpty)
        .sensoryFeedback(.start, trigger: started)
        .sensoryFeedback(.success, trigger: finished)
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

    private func isDownloading(_ state: Downloads.State) -> Bool {
        if case .downloading = state { return true }
        return false
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

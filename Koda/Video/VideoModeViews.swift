import AVFoundation
import KodaCore
import SwiftUI

/// Music or Video, at the top of Home (iPhone) and of the sidebar (Mac): the whole app follows it,
/// as Koda for Android's toggle does.
struct ModeToggle: View {
    @Environment(AppModel.self) private var app
    @State private var flips = 0

    var body: some View {
        Picker("Mode", selection: Binding(get: { app.settings.mode }, set: { mode in
            flips += 1
            withAnimation(.smooth) { app.settings.mode = mode }
        })) {
            ForEach(AppSettings.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .sensoryFeedback(.selection, trigger: flips)
        .accessibilityLabel("Mode")
    }
}

/// Video mode's Search tab: YouTube's results, channels first.
struct VideoSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var search = VideoSearchModel()

    var body: some View {
        @Bindable var search = search
        ScrollView {
            if search.submitted != nil {
                VideoSearchResultsView(model: search)
            } else if !library.watched.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    RecentlyWatchedShelf(videos: Array(library.watched.prefix(12)))
                }
                .padding(.vertical, 8)
            }
        }
        .overlay {
            if search.submitted == nil, library.watched.isEmpty {
                ContentUnavailableView("Search YouTube", systemImage: "magnifyingglass",
                                       description: Text("Find videos and channels."))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, prompt: "Videos and channels")
        .onSubmit(of: .search) { Task { await search.search(search.query, music: app.music) } }
        .onChange(of: search.query) { _, text in if text.isEmpty { search.clear() } }
    }
}

/// Video mode's Library: what was watched, most recent first, to go back to or remove.
struct VideoLibraryView: View {
    @Environment(Library.self) private var library
    @State private var confirmsClear = false

    var body: some View {
        Group {
            if Platform.isMac {
                MacPage {
                    MacPageTitle(title: "Watched") {
                        if !library.watched.isEmpty {
                            Button("Clear…") { confirmsClear = true }
                        }
                    }
                    if library.watched.isEmpty {
                        empty.frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 20, alignment: .top)], spacing: 26) {
                            ForEach(library.watched) { video in
                                NavigationLink(value: Route.video(video)) { VideoCard(video: video, width: 360) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Remove from Watched", systemImage: "trash", role: .destructive) { library.removeWatched(video.id) }
                                    }
                            }
                        }
                    }
                }
            } else {
                List {
                    ForEach(library.watched) { video in
                        NavigationLink(value: Route.video(video)) { VideoRow(video: video) }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    withAnimation { library.removeWatched(video.id) }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .overlay { if library.watched.isEmpty { empty } }
                .toolbar {
                    if !library.watched.isEmpty {
                        Button("Clear", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .navigationTitle(Platform.isMac ? "Watched" : "Library")
        .confirmationDialog("Clear what you've watched?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Watched", role: .destructive) {
                for video in library.watched { library.removeWatched(video.id) }
            }
        } message: {
            Text("Videos you've watched are removed from this list and no longer shape the Home feed.")
        }
    }

    private var empty: some View {
        ContentUnavailableView("Nothing Watched Yet", systemImage: "play.rectangle",
                               description: Text("Videos you watch appear here."))
    }
}

/// Under the player: quality, speed, captions (when the video has them) and share.
struct VideoControlsRow: View {
    let playback: VideoPlayback
    let shareURL: URL
    let title: String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Quality", selection: Binding(get: { playback.quality }, set: { playback.setQuality($0) })) {
                        Text("Auto").tag(0)
                        ForEach(playback.qualities, id: \.self) { lines in
                            Text(Self.name(lines)).tag(lines)
                        }
                    }
                } label: {
                    Label(playback.quality == 0 ? "Auto" : Self.name(playback.quality), systemImage: "dial.medium")
                }
                .disabled(playback.qualities.isEmpty)
                .accessibilityLabel("Quality, \(playback.quality == 0 ? "Auto" : Self.name(playback.quality))")

                Menu {
                    Picker("Speed", selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) })) {
                        ForEach(VideoPlayback.speeds, id: \.self) { rate in
                            Text(rate == 1 ? "Normal" : Self.speedName(rate)).tag(rate)
                        }
                    }
                } label: {
                    Label(Self.speedName(playback.speed), systemImage: "gauge.with.dots.needle.67percent")
                }
                .accessibilityLabel("Speed, \(Self.speedName(playback.speed))")

                if !playback.captions.isEmpty {
                    Menu {
                        Picker("Captions", selection: Binding(get: { playback.caption }, set: { playback.setCaption($0) })) {
                            Text("Off").tag(AVMediaSelectionOption?.none)
                            ForEach(playback.captions, id: \.self) { option in
                                Text(option.displayName).tag(Optional(option))
                            }
                        }
                    } label: {
                        Label(playback.caption?.displayName ?? "Captions",
                              systemImage: playback.caption == nil ? "captions.bubble" : "captions.bubble.fill")
                    }
                }

                ShareLink(item: shareURL, subject: Text(title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.glass)
            .menuStyle(.button)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    static func name(_ lines: Int) -> String {
        switch lines {
        case 2160...: "4K"
        case 1440...: "1440p"
        default: "\(lines)p"
        }
    }

    static func speedName(_ rate: Float) -> String {
        rate == 1 ? "1×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

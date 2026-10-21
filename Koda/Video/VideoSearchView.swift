import KodaCore
import SwiftUI

struct VideoSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(VideoModel.self) private var model

    var body: some View {
        searchContent(model)
    }

    @ViewBuilder
    private func searchContent(_ model: VideoModel) -> some View {
        @Bindable var model = model
        Group {
            if model.submitted != nil {
                results(model)
            } else {
                landing
            }
        }
        .navigationTitle("Search")
        .searchable(text: $model.query, prompt: "Videos, channels, playlists")
        .onSubmit(of: .search) { submit(model.query, model: model) }
        .onChange(of: model.query) { _, text in
            if text.isEmpty { model.clearSearch() }
        }
        .task(id: model.filter) {
            if model.submitted != nil { await model.runSearch() }
        }
    }

    private var landing: some View {
        ContentUnavailableView("Search Videos", systemImage: "magnifyingglass", description: Text("Find videos, channels and playlists."))
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func results(_ model: VideoModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                filterChips(model)
                if let state = model.searchResults {
                    AsyncContent(state: state, retry: { await model.runSearch() }, placeholder: .placeholder) { found in
                        if found.videos.isEmpty && found.channels.isEmpty && found.playlists.isEmpty {
                            ContentUnavailableView.search(text: model.submitted ?? "")
                        } else {
                            resultsContent(found, model: model)
                            if model.searchResults?.value?.continuation != nil {
                                HStack { Spacer(); ProgressView(); Spacer() }
                                    .padding()
                                    .task(id: model.searchResults?.value?.continuation) { await model.loadMoreSearch() }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func resultsContent(_ found: VideoSearchResults, model: VideoModel) -> some View {
        switch model.filter {
        case .all:
            if !found.videos.isEmpty {
                section("Videos") {
                    ForEach(found.videos) { video in
                        VideoRow(video: video) { play(video, in: found.videos) }
                    }
                }
            }
            if !found.channels.isEmpty {
                section("Channels") {
                    ForEach(found.channels) { channel in
                        channelRow(channel)
                    }
                }
            }
            if !found.playlists.isEmpty {
                section("Playlists") {
                    ForEach(found.playlists) { playlist in
                        NavigationLink(value: Route.videoPlaylist(playlist)) {
                            HStack {
                                VideoThumbnail(artwork: playlist.thumbnail, cornerRadius: 8)
                                    .frame(width: 80, height: 45)
                                Text(playlist.title).font(.body)
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .videos, .shorts:
            LazyVStack(spacing: 0) {
                ForEach(found.videos) { video in
                    VideoRow(video: video) { play(video, in: found.videos) }
                }
            }
            .padding(.horizontal, 20)
        case .channels:
            LazyVStack(spacing: 0) {
                ForEach(found.channels) { channel in
                    channelRow(channel)
                }
            }
            .padding(.horizontal, 20)
        case .playlists:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 20) {
                ForEach(found.playlists) { playlist in
                    NavigationLink(value: Route.videoPlaylist(playlist)) {
                        VStack(alignment: .leading, spacing: 6) {
                            VideoThumbnail(artwork: playlist.thumbnail, cornerRadius: 10)
                                .frame(height: 90)
                            Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                            if let channel = playlist.channel {
                                Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold()).padding(.horizontal, 20)
            LazyVStack(spacing: 0) { content() }.padding(.horizontal, 20)
        }
    }

    private func channelRow(_ channel: VideoChannel) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: channel.avatar, size: 48, circle: true)
            VStack(alignment: .leading) {
                Text(channel.name).font(.body)
                if let subs = channel.subscriberText {
                    Text(subs).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    private func filterChips(_ model: VideoModel) -> some View {
        @Bindable var model = model
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(VideoSearchFilter.allCases, id: \.self) { filter in
                    let selected = filter == model.filter
                    Button(filter.title) { model.filter = filter }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(selected ? .accentColor : .secondary)
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .sensoryFeedback(.selection, trigger: model.filter)
    }

    private func submit(_ text: String, model: VideoModel) {
        // A pasted YouTube link opens what it points at instead of searching for the URL.
        if let link = YouTubeLink(text: text) {
            model.query = ""
            model.clearSearch()
            app.openLink(link)
            return
        }
        Task { await model.search(text) }
    }

    private func play(_ video: VideoItem, in videos: [VideoItem]) {
        app.videoPlayback.playQueue(videos, startAt: videos.firstIndex(where: { $0.id == video.id }) ?? 0)
    }
}

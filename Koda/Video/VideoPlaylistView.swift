import KodaCore
import SwiftUI

struct VideoPlaylistView: View {
    let summary: VideoPlaylistSummary

    @Environment(AppModel.self) private var app
    @Environment(VideoPlayback.self) private var playback
    @Environment(VideoModel.self) private var model

    var body: some View {
        ScrollView {
            AsyncContent(state: model.playlist, retry: { await model.loadPlaylist(summary.id) }, placeholder: .placeholder) { page in
                if page.items.isEmpty {
                    ContentUnavailableView("No Videos", systemImage: "play.rectangle")
                        .frame(minHeight: 300)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            VideoThumbnail(artwork: page.playlist.thumbnail ?? summary.thumbnail, cornerRadius: 10)
                                .frame(width: 96, height: 54)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.playlist.title).font(.title3.bold()).lineLimit(2)
                                if let channel = page.playlist.channel {
                                    Text(channel).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let count = page.playlist.itemCount {
                                    Text("\(count) videos").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)

                        Button {
                            playback.playQueue(page.items)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .padding(.horizontal, 20)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(page.items.enumerated()), id: \.element.id) { index, item in
                                VideoRow(video: item) {
                                    playback.playQueue(page.items, startAt: index)
                                }
                                .padding(.horizontal, 20)
                            }
                            if model.playlist?.value?.continuation != nil {
                                HStack { Spacer(); ProgressView(); Spacer() }
                                    .padding()
                                    .task(id: model.playlist?.value?.continuation) { await model.loadMorePlaylist() }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(summary.title)
        .refreshable { await model.loadPlaylist(summary.id) }
        .task(id: summary.id) { await model.loadPlaylist(summary.id) }
    }
}

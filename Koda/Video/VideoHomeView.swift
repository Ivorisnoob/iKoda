import KodaCore
import SwiftUI

struct VideoHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(VideoModel.self) private var model

    var body: some View {
        ScrollView {
            AsyncContent(state: model.feed, retry: { await model.loadFeed() }, placeholder: .placeholder) { feed in
                if feed.shelves.isEmpty {
                    ContentUnavailableView {
                        Label("No Videos", systemImage: "play.rectangle")
                    } description: {
                        Text(app.account.isSignedIn ? "No videos found." : "Sign in to see your video feed.")
                    } actions: {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(["Music videos", "Podcasts", "Gaming", "News", "Cooking"], id: \.self) { query in
                                    Button(query) {
                                        model.query = query
                                        model.submitted = query
                                        Task { await model.runSearch() }
                                        app.open(.videoSearch)
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(feed.shelves) { shelf in
                            ShelfView(title: shelf.title) {
                                ForEach(shelf.items) { video in
                                    NavigationLink(value: Route.video(video)) {
                                        VideoCard(video: video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if model.feed.value?.continuation != nil {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding()
                                .task(id: model.feed.value?.continuation) { await model.loadMoreFeed() }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Videos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.videoSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search Videos")
            }
        }
        .refreshable { await model.loadFeed() }
        .task { if case .loading = model.feed { await model.loadFeed() } }
    }
}
import KodaCore
import SwiftUI

/// Shuffle, repeat and autoplay over the list of what plays next.
struct QueuePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    /// What the last Clear or Remove took out, offered back for a few seconds.
    @State private var undo: Undo?
    @State private var removals = 0

    private enum Undo: Equatable {
        case cleared([Song])
        /// One song, and where it stood among the upcoming ones.
        case removed(Song, at: Int)

        var label: String {
            switch self {
            case .cleared: "Undo"
            case .removed: "Undo Remove"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            modeToggles
            // Above the list rather than a sticky section header: iOS draws those on a band
            // of their own, which showed as an outline over the songs scrolling under it.
            HStack {
                Text(player.upcoming.isEmpty ? "Nothing Up Next" : "Up Next")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let undo {
                    Button(undo.label) { perform(undo) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                } else if !player.upcoming.isEmpty {
                    Button("Clear") { clear() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: undo)
            List {
                Section {
                    ForEach(player.upcoming) { item in
                        QueueRow(song: item.song)
                            .contentShape(.rect)
                            .onTapGesture { player.jump(to: item.id) }
                            // The cover lines up with the toggles and the heading above.
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(.primary.opacity(0.15))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(item) }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { moveToTop(item) }
                                    .tint(.indigo)
                            }
                            .contextMenu { menu(for: item) }
                            .accessibilityAction(named: "Remove from Queue") { remove(item) }
                            .accessibilityAction(named: "Play Next") { moveToTop(item) }
                    }
                    // Outside edit mode a row is picked up with a long press and dragged. Edit
                    // mode would show grab handles, but it also switches every swipe action off,
                    // which left songs impossible to remove.
                    .onMove { source, destination in player.moveUpcoming(fromOffsets: source, toOffset: destination) }
                }
            }
            .listStyle(.plain)
            // Shuffle reorders every row; a fresh list draws only the rows on screen,
            // where diffing would animate a move for each of hundreds of songs.
            .id(player.isShuffled)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollContentBackground(.hidden)
            .sensoryFeedback(.impact(weight: .light), trigger: removals)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .task(id: undo) {
            guard undo != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            undo = nil
        }
    }

    @ViewBuilder
    private func menu(for item: QueueItem) -> some View {
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { moveToTop(item) }
            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) { remove(item) }
        }
        Section {
            let liked = library.isLiked(item.song)
            Button(liked ? "Remove from Liked" : "Like", systemImage: liked ? "heart.slash" : "heart") { library.toggleLike(item.song) }
            AddToPlaylistMenu(songs: [item.song])
            if let album = item.song.album {
                Button("Go to Album", systemImage: "square.stack") {
                    model.open(.album(AlbumSummary(id: album.id, title: album.title, artistLine: item.song.artistLine,
                                                   artists: item.song.artists, artwork: item.song.artwork)))
                }
            }
            GoToArtistItems(song: item.song) { model.open(.artist($0)) }
        }
    }

    private func remove(_ item: QueueItem) {
        guard let index = player.upcoming.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation { player.remove(item.id) }
        undo = .removed(item.song, at: index)
        removals += 1
    }

    private func moveToTop(_ item: QueueItem) {
        guard let index = player.upcoming.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        withAnimation { player.moveUpcoming(fromOffsets: [index], toOffset: 0) }
    }

    private func clear() {
        undo = .cleared(player.upcoming.map(\.song))
        withAnimation { player.clearUpcoming() }
    }

    private func perform(_ undo: Undo) {
        self.undo = nil
        withAnimation {
            switch undo {
            case .cleared(let songs):
                // Autoplay may have filled the queue again since; what was cleared comes back in its place.
                player.clearUpcoming()
                player.addToQueue(songs)
            case .removed(let song, let index):
                // Back where it was: inserted first, then moved down; a move to offset n lands it at n - 1.
                player.playNext([song])
                if index > 0 { player.moveUpcoming(fromOffsets: [0], toOffset: min(index, player.upcoming.count - 1) + 1) }
            }
        }
    }

    private var modeToggles: some View {
        HStack(spacing: 8) {
            toggle("Shuffle", systemImage: "shuffle", isOn: player.isShuffled) {
                player.setShuffle(!player.isShuffled)
            }
            toggle(player.repeatMode == .one ? "Repeat One" : "Repeat",
                   systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                   isOn: player.repeatMode != .off) {
                player.cycleRepeat()
            }
            toggle("Autoplay", systemImage: "infinity", isOn: player.autoplay) {
                player.autoplay.toggle()
            }
            toggle("AutoMix", systemImage: "waveform", isOn: player.autoMix) {
                player.autoMix.toggle()
            }
        }
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PlayerToggleStyle(isOn: isOn, offFill: 0.12))
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct QueueRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: song.artwork, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(song.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
    }
}

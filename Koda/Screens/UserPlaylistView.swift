import KodaCore
import SwiftUI

/// A playlist made on this phone: play it, reorder it, rename or delete it.
struct UserPlaylistView: View {
    let id: UUID

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmDelete = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        if let playlist = library.userPlaylist(id) {
            if Platform.isMac { macContent(playlist) } else { content(playlist) }
        } else {
            ContentUnavailableView("Playlist Deleted", systemImage: "music.note.list")
        }
    }

    private func content(_ playlist: UserPlaylist) -> some View {
        List {
            header(playlist)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

            ForEach(Array(playlist.songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song) { player.play(playlist.songs, startAt: index) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .leading) {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([song]) }
                            .tint(.indigo)
                    }
            }
            .onDelete { library.removeSongs(atOffsets: $0, fromPlaylist: id) }
            .onMove { library.moveSongs(fromOffsets: $0, toOffset: $1, inPlaylist: id) }

            if playlist.songs.isEmpty {
                ContentUnavailableView {
                    Label("No Songs Yet", systemImage: "music.note.list")
                } description: {
                    Text("Long-press any song, or open its ••• menu, and choose Add to Playlist.")
                } actions: {
                    Button("Find Music") {
                        app.selectedTab = .search
                    }
                    .buttonStyle(.glass)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .background { PlaylistGlow(songs: playlist.songs) }
        .navigationBarTitleDisplayMode(.inline)
        .revealsTitle(playlist.name, after: 300)
        .toolbar {
            if !playlist.songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .fontWeight(editMode.isEditing ? .semibold : .regular)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    DownloadButton(songs: playlist.songs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    if !playlist.songs.isEmpty {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(playlist.songs) }
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(playlist.songs) }
                    }
                    Button("Rename", systemImage: "pencil") {
                        draftName = playlist.name
                        renaming = true
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.renamePlaylist(id, to: draftName) }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                dismiss()
                library.deletePlaylist(id)
            }
        } message: {
            Text("The songs stay wherever else you saved them.")
        }
    }

    /// The Mac's playlist page: the mosaic beside the name, songs in columns, and each song's
    /// menu able to move it or take it out, where the phone drags and swipes.
    private func macContent(_ playlist: UserPlaylist) -> some View {
        MacPage(spacing: 28) {
            MacCollectionHeader(
                kind: "Your Playlist",
                title: playlist.name,
                byline: nil,
                detail: detail(playlist),
                canPlay: !playlist.songs.isEmpty,
                play: { player.play(playlist.songs) },
                shuffle: { player.play(playlist.songs, startAt: Int.random(in: 0..<max(playlist.songs.count, 1)), shuffled: true) }
            ) { side in
                PlaylistMosaic(songs: playlist.songs, size: side, cornerRadius: 12)
            } actions: {
                if !playlist.songs.isEmpty {
                    DownloadButton(songs: playlist.songs)
                        .buttonStyle(MacIconButtonStyle())
                }
                MacMoreMenu {
                    if !playlist.songs.isEmpty {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(playlist.songs) }
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(playlist.songs) }
                        Divider()
                    }
                    Button("Rename…", systemImage: "pencil") {
                        draftName = playlist.name
                        renaming = true
                    }
                    Button("Delete Playlist…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            if playlist.songs.isEmpty {
                ContentUnavailableView {
                    Label("No Songs Yet", systemImage: "music.note.list")
                } description: {
                    Text("Right-click any song, or open its ••• menu, and choose Add to Playlist.")
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                MacTrackList(songs: playlist.songs, play: { player.play(playlist.songs, startAt: $0) }, rowMenu: { index in
                    AnyView(Section {
                        Button("Move Up", systemImage: "arrow.up") {
                            library.moveSongs(fromOffsets: IndexSet(integer: index), toOffset: index - 1, inPlaylist: id)
                        }
                        .disabled(index == 0)
                        Button("Move Down", systemImage: "arrow.down") {
                            library.moveSongs(fromOffsets: IndexSet(integer: index), toOffset: index + 2, inPlaylist: id)
                        }
                        .disabled(index >= playlist.songs.count - 1)
                        Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                            library.removeSongs(atOffsets: IndexSet(integer: index), fromPlaylist: id)
                        }
                    })
                })
            }
        }
        .background { PlaylistGlow(songs: playlist.songs) }
        .navigationTitle(playlist.name)
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.renamePlaylist(id, to: draftName) }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { library.deletePlaylist(id) }
        } message: {
            Text("The songs stay wherever else you saved them.")
        }
    }

    private func header(_ playlist: UserPlaylist) -> some View {
        VStack(spacing: 14) {
            PlaylistMosaic(songs: playlist.songs, size: 232, cornerRadius: 16)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(detail(playlist))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !playlist.songs.isEmpty {
                PlayShuffleButtons(play: { player.play(playlist.songs) }, shuffle: {
                    player.play(playlist.songs, startAt: Int.random(in: 0..<playlist.songs.count), shuffled: true)
                })
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(_ playlist: UserPlaylist) -> String {
        var parts = ["Made by \(app.roster.active.displayName)"]
        parts.append(playlist.songs.count == 1 ? "1 song" : "\(playlist.songs.count) songs")
        let minutes = Int(playlist.duration / 60)
        if minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min") }
        return parts.joined(separator: " · ")
    }
}

/// A playlist's cover: the first four distinct covers in a grid, one when there are fewer, a gradient when there are none.
struct PlaylistMosaic: View {
    let songs: [Song]
    var size: CGFloat
    var cornerRadius: CGFloat = 10

    private var covers: [Artwork] {
        var seen = Set<URL>()
        return songs.compactMap(\.artwork).filter { seen.insert($0.url(pixels: 120)).inserted }.prefix(4).map { $0 }
    }

    var body: some View {
        let covers = covers
        ZStack {
            if covers.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(artwork: covers[0], size: half, cornerRadius: 0)
                        ArtworkView(artwork: covers[1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(artwork: covers[2], size: half, cornerRadius: 0)
                        ArtworkView(artwork: covers[3], size: half, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(artwork: first, size: size, cornerRadius: 0)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// The colour of the playlist's first cover behind its header, as album pages have.
private struct PlaylistGlow: View {
    let songs: [Song]
    @State private var palette = PaletteModel()

    var body: some View {
        ArtworkGlow(palette: palette.palette)
            .task(id: songs.first?.artwork) { await palette.load(songs.first?.artwork) }
    }
}

/// Pick one of the listener's playlists, or make a new one, for some songs.
struct AddToPlaylistSheet: View {
    let target: AppModel.PlaylistTarget

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var draftName = ""
    @State private var added = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        draftName = ""
                        naming = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 52, height: 52)
                                .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
                            Text("New Playlist").font(.body.weight(.medium))
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !library.userPlaylists.isEmpty {
                    Section("Your Playlists") {
                        ForEach(library.userPlaylists) { playlist in
                            let containsAll = Set(target.songs.map(\.id)).isSubset(of: Set(playlist.songs.map(\.id)))
                            Button {
                                added += 1
                                library.add(target.songs, toPlaylist: playlist.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    PlaylistMosaic(songs: playlist.songs, size: 52, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                                        Text(playlist.songs.count == 1 ? "1 song" : "\(playlist.songs.count) songs")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if containsAll {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                            .accessibilityLabel("Already added")
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(containsAll)
                        }
                    }
                }
            }
            .navigationTitle(target.songs.count == 1 ? "Add to Playlist" : "Add \(target.songs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $naming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    added += 1
                    library.createPlaylist(named: draftName, songs: target.songs)
                    dismiss()
                }
            } message: {
                Text(target.songs.count == 1 ? "“\(target.songs[0].title)” will be its first song." : "These \(target.songs.count) songs will be its first.")
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.success, trigger: added)
    }
}

extension View {
    /// Shows the playlist picker when `AppModel.playlistTarget` is set and this screen is the one on top.
    func playlistPicker(whenOnTop isOnTop: Bool) -> some View {
        modifier(PlaylistPickerModifier(isOnTop: isOnTop))
    }
}

private struct PlaylistPickerModifier: ViewModifier {
    let isOnTop: Bool
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { isOnTop ? app.playlistTarget : nil },
            set: { if isOnTop { app.playlistTarget = $0 } })) { target in
            Group {
                if Platform.isMac { MacNewPlaylistSheet(target: target) } else { AddToPlaylistSheet(target: target) }
            }
            .appEnvironment(app)
        }
    }
}


/// "Add to Playlist" in a song's or a collection's menu. On the Mac it is a submenu of the
/// listener's playlists, as Music's is, with New Playlist… first; on the iPhone it opens the sheet.
struct AddToPlaylistMenu: View {
    let songs: [Song]
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        if Platform.isMac {
            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                Button("New Playlist…", systemImage: "plus") { app.addToPlaylist(songs) }
                if !library.userPlaylists.isEmpty {
                    Divider()
                    ForEach(library.userPlaylists) { playlist in
                        let containsAll = Set(songs.map(\.id)).isSubset(of: Set(playlist.songs.map(\.id)))
                        Button(playlist.name, systemImage: containsAll ? "checkmark" : "music.note.list") {
                            library.add(songs, toPlaylist: playlist.id)
                        }
                        .disabled(containsAll)
                    }
                }
            }
        } else {
            Button("Add to Playlist…", systemImage: "text.badge.plus") { app.addToPlaylist(songs) }
        }
    }
}

/// A new playlist from songs on the Mac: a small sheet asking only for its name.
struct MacNewPlaylistSheet: View {
    let target: AppModel.PlaylistTarget
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                PlaylistMosaic(songs: target.songs, size: 64, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Playlist").font(.headline)
                    Text(target.songs.count == 1 ? "With “\(target.songs[0].title)”" : "With these \(target.songs.count) songs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Playlist", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = "Playlist \(library.userPlaylists.count + 1)"
            focused = true
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let playlist = library.createPlaylist(named: trimmed, songs: target.songs)
        dismiss()
        app.requestedMacSection = .userPlaylist(playlist.id)
    }
}

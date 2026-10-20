import KodaCore
import SwiftUI

/// The roster of profiles: who the app is being right now, and who else it
/// could be.
///
/// A page rather than a sheet: it is pushed into the caller's stack, so it
/// never has to be presented over another sheet, which is where the app
/// stopped answering. Switching is instant and offline — the sessions are
/// already on the device — so there is nothing to wait for and nothing to
/// confirm.
struct ProfileSwitcherView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showsSignIn = false
    @State private var renaming: KodaProfile?
    @State private var choosingAvatar: KodaProfile?
    @State private var removing: KodaProfile?

    var body: some View {
        List {
            Section {
                ForEach(app.account.roster) { profile in
                    row(profile)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each profile keeps its own liked songs, history, stats and playlists. Switching is instant and works without a connection.")
            }
            Section {
                Button { showsSignIn = true } label: {
                    Label("Add YouTube Account", systemImage: "play.rectangle.fill")
                }
                Button { addProfileOnThisDevice() } label: {
                    Label("Add On-Device Profile", systemImage: "iphone")
                }
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSignIn) {
            YouTubeSignInView { header in
                Task { await app.account.signIn(cookieHeader: header) }
            }
        }
        .sheet(item: $renaming) { profile in
            RenameProfileSheet(profile: profile)
        }
        .sheet(item: $choosingAvatar) { profile in
            AvatarPickerSheet(profile: profile)
        }
        .confirmationDialog("Remove this profile?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { profile in
            Button("Remove Profile", role: .destructive) {
                app.account.remove(profile.id)
                removing = nil
            }
        } message: { profile in
            Text("\(profile.displayName) is removed from this device. What it played and liked stays on the device, out of reach.")
        }
        .task { app.profile.preparePhotos(for: app.account.roster) }
    }

    // MARK: A profile

    private func row(_ profile: KodaProfile) -> some View {
        Button {
            app.switchProfile(to: profile.id)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                ProfileAvatar(profile: profile, photo: app.profile.photo(for: profile), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body.weight(profile.id == app.profiles.activeID ? .semibold : .regular))
                        .lineLimit(1)
                    Text(subtitle(for: profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if profile.id == app.profiles.activeID {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { renaming = profile }
            Button("Choose Avatar", systemImage: "face.smiling") { choosingAvatar = profile }
            if app.profiles.profiles.count > 1 {
                Button("Remove Profile", systemImage: "trash", role: .destructive) { removing = profile }
            }
        }
    }

    /// What a row says under the name.
    private func subtitle(for profile: KodaProfile) -> String {
        if app.account.needsSignIn.contains(profile.id) {
            return "Needs signing in"
        }
        return profile.subtitle
    }

    private func addProfileOnThisDevice() {
        let profile = app.profiles.addLocal()
        app.switchProfile(to: profile.id)
    }
}

/// A profile's name, changed in one field.
private struct RenameProfileSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: KodaProfile
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.givenName)
                } footer: {
                    Text("Shown on the profile and on the playlists it makes. It stays on this device.")
                }
            }
            .navigationTitle("Rename Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.profiles.rename(profile.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
        .onAppear { name = profile.name }
        .presentationDetents([.height(220)])
    }
}

/// A profile's drawn avatar: a grid of them to choose from.
private struct AvatarPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: KodaProfile
    @State private var seed: UInt64 = 0x5EED

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 16) {
                    ForEach(0..<24, id: \.self) { index in
                        Button {
                            app.profiles.setAvatar(profile.id, avatar: avatar(index))
                            dismiss()
                        } label: {
                            KodaAvatarView(avatar: avatar(index), size: 68)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Choose an Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Shuffle", systemImage: "shuffle") { seed &+= 0x9E37 }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func avatar(_ index: Int) -> KodaAvatar {
        KodaAvatar.random(seed: seed &+ UInt64(index) &* 0x9E3779B97F4A7C15)
    }
}

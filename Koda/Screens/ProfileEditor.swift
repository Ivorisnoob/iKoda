import KodaCore
import PhotosUI
import SwiftUI

// MARK: - Avatar editor

/// Choosing a drawn avatar: each option is drawn as the avatar it would make, so the row of
/// choices previews the result rather than naming it.
struct AvatarEditor: View {
    @Binding var avatar: KodaAvatar
    var swatch: CGFloat = 52
    @State private var rolls = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("Shape", count: KodaAvatar.shapes, selected: avatar.shapeIndex) { $0.shape = $1 }
            row("Colour", count: KodaAvatar.colors, selected: avatar.colorIndex, name: { KodaAvatar.colorways[$0].name }) { $0.color = $1 }
            row("Eyes", count: KodaAvatar.eyeStyles, selected: avatar.eyesIndex) { $0.eyes = $1 }
            row("Mouth", count: KodaAvatar.mouths, selected: avatar.mouthIndex) { $0.mouth = $1 }
            row("Extra", count: KodaAvatar.extras, selected: avatar.extraIndex, name: { $0 == 0 ? "None" : "Extra \($0)" }) { $0.extra = $1 }
            HStack {
                Toggle("Rosy Cheeks", isOn: $avatar.blush)
                    .fixedSize()
                Spacer()
                Button("Surprise Me", systemImage: "dice") {
                    rolls += 1
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) { avatar = .random() }
                }
                .buttonStyle(.glass)
                .sensoryFeedback(.impact(weight: .light), trigger: rolls)
            }
        }
    }

    private func row(_ title: String, count: Int, selected: Int, name: ((Int) -> String)? = nil,
                     _ apply: @escaping (inout KodaAvatar, Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { index in
                        let option = { var a = avatar; apply(&a, index); return a }()
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { apply(&avatar, index) }
                        } label: {
                            KodaAvatarView(avatar: option, size: swatch)
                                .padding(4)
                                .overlay {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        .opacity(index == selected ? 1 : 0)
                                }
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name?(index) ?? "\(title) \(index + 1)") of \(count)")
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .sensoryFeedback(.selection, trigger: selected)
        }
    }
}

// MARK: - Editing a profile

/// One profile's name and picture, its account, and deleting it. A Form, shown in a sheet on
/// the iPhone; the Mac's Settings has its own pane with the same parts.
struct ProfileEditorView: View {
    let profileID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = KodaAvatar()
    @State private var photo: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var confirmSignOut = false

    private var profile: KodaProfile? { app.roster.profile(profileID) }

    var body: some View {
        NavigationStack {
            if let profile {
                form(profile)
            }
        }
        .onAppear {
            guard let profile else { return }
            name = profile.name
            avatar = profile.avatar
        }
    }

    private func form(_ profile: KodaProfile) -> some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    ProfileAvatar(profile: profile, size: 112)
                        .animation(.snappy, value: profile)
                    TextField("Name", text: $name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    Text(profile.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(profile.isExpired ? .red : .secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Picture") {
                Picker("Picture", selection: Binding(get: { profile.picture }, set: { choose($0, for: profile) })) {
                    Text("Koda Face").tag(KodaProfile.Picture.drawn)
                    Text("Photo").tag(KodaProfile.Picture.photo)
                    if profile.accountPhoto != nil { Text("Google").tag(KodaProfile.Picture.account) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                switch profile.picture {
                case .drawn:
                    AvatarEditor(avatar: $avatar)
                        .padding(.vertical, 6)
                case .photo:
                    PhotosPicker(app.profilePhotos.photo(for: profile) == nil ? "Choose Photo…" : "Choose Another Photo…",
                                 selection: $photo, matching: .images)
                case .account:
                    Text("Your Google account's picture. It changes when you change it on Google.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            AccountSection(profile: profile, confirmSignOut: $confirmSignOut)

            if app.roster.profiles.count > 1 {
                Section {
                    Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deletes this profile's liked songs, playlists, history and stats from this \(Platform.isMac ? "Mac" : "iPhone").")
                }
            }
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    saveName()
                    dismiss()
                }
            }
        }
        .onChange(of: avatar) { _, avatar in app.roster.update(profileID) { $0.avatar = avatar } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                app.profilePhotos.setPhoto(data, for: profileID)
                photo = nil
            }
        }
        .confirmationDialog("Delete “\(profile.displayName)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                app.deleteProfile(profileID)
                dismiss()
            }
        } message: {
            Text("Its liked songs, playlists, history and stats are deleted from this device. \(profile.isSignedIn ? "Your YouTube Music account isn't affected." : "")")
        }
    }

    private func saveName() {
        app.roster.update(profileID) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func choose(_ picture: KodaProfile.Picture, for profile: KodaProfile) {
        app.roster.update(profileID) { $0.picture = picture }
    }
}

/// The profile's YouTube Music account: signing in, the account it is signed in to, and
/// signing out, which keeps the profile and everything in it on this device.
private struct AccountSection: View {
    let profile: KodaProfile
    @Binding var confirmSignOut: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            if profile.isSignedIn {
                LabeledContent("YouTube Music", value: profile.handle ?? profile.displayName)
                if profile.isExpired {
                    NavigationLink("Sign In Again") { YouTubeSignInView(into: profile.id) }
                }
                Button("Sign Out…", role: .destructive) { confirmSignOut = true }
            } else {
                NavigationLink("Sign In to YouTube Music") { YouTubeSignInView(into: profile.id) }
            }
        } header: {
            Text("Account")
        } footer: {
            Text(profile.isSignedIn
                 ? "Home and your library follow your YouTube Music account."
                 : "Sign in to bring your YouTube Music likes, playlists and Home to this profile. Everything already here stays.")
        }
        .confirmationDialog("Sign out of YouTube Music?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.signOut(profile.id) }
        } message: {
            Text("“\(profile.displayName)” stays on this device with its likes, playlists and history.")
        }
    }
}

// MARK: - Adding a profile

/// A new profile: signed in to YouTube Music, or kept on this device with a name and a face.
struct AddProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = KodaAvatar.random()
    @State private var makesLocal = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if makesLocal { local } else { choices }
            }
            .navigationTitle(makesLocal ? "New Profile" : "Add Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                if makesLocal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", systemImage: "checkmark") { addLocal() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents(makesLocal ? [.large] : [.medium, .large])
        .frame(minWidth: Platform.isMac ? 460 : nil, minHeight: Platform.isMac ? 520 : nil)
    }

    private var choices: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Each profile has its own likes, playlists, history and Home.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                NavigationLink {
                    YouTubeSignInView(into: nil) { dismiss() }
                } label: {
                    choice(title: "Sign In to YouTube Music", detail: "Your account's likes, playlists and Home, kept in step.",
                           systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
                Button {
                    withAnimation(.smooth) { makesLocal = true }
                } label: {
                    choice(title: "Profile on This \(Platform.isMac ? "Mac" : "iPhone")", detail: "No account needed. Everything stays on this device.",
                           systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
            }
            .padding(20)
        }
    }

    private func choice(title: String, detail: String, systemImage: String) -> some View {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(.rect)
    }

    private var local: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    KodaAvatarView(avatar: avatar, size: 112)
                    TextField("Name", text: $name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(addLocal)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section("Face") {
                AvatarEditor(avatar: $avatar)
                    .padding(.vertical, 6)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func addLocal() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let profile = app.roster.addDeviceProfile(named: trimmed)
        app.roster.update(profile.id) { $0.avatar = avatar }
        app.switchProfile(to: profile.id)
        dismiss()
    }
}

// MARK: - Every profile

/// All profiles as a grid of faces, as the TV app and streaming services ask "who's
/// listening?": a tap switches, Edit opens one to change or delete.
struct ProfilesGrid: View {
    @Environment(AppModel.self) private var app
    var onSwitch: () -> Void = {}
    @State private var editing: UUID?
    @State private var adding = false
    @State private var switches = 0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 16)], spacing: 18) {
            ForEach(app.roster.profiles) { profile in
                let isActive = profile.id == app.roster.activeID
                Button {
                    if isActive {
                        editing = profile.id
                    } else {
                        switches += 1
                        app.switchProfile(to: profile.id)
                        onSwitch()
                    }
                } label: {
                    VStack(spacing: 8) {
                        ProfileAvatar(profile: profile, size: 76)
                            .overlay(alignment: .bottomTrailing) {
                                if isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .background(Circle().fill(.background))
                                        .offset(x: 2, y: 2)
                                }
                            }
                        Text(profile.displayName)
                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                            .lineLimit(1)
                        Text(profile.subtitle)
                            .font(.caption)
                            .foregroundStyle(profile.isExpired ? .red : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !isActive {
                        Button("Switch to \(profile.displayName)", systemImage: "arrow.left.arrow.right") {
                            app.switchProfile(to: profile.id)
                            onSwitch()
                        }
                    }
                    Button("Edit Profile…", systemImage: "pencil") { editing = profile.id }
                }
                .accessibilityLabel("\(profile.displayName), \(profile.subtitle)")
                .accessibilityHint(isActive ? "Current profile. Double-tap to edit." : "Double-tap to switch to this profile.")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Button { adding = true } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.title.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 76, height: 76)
                        .background(.fill.tertiary, in: .circle)
                    Text("Add").font(.subheadline)
                    Text(" ").font(.caption)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Profile")
        }
        .sensoryFeedback(.selection, trigger: switches)
        .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
            ProfileEditorView(profileID: item.id).appEnvironment(app)
        }
        // Its own sheet: this grid sits inside the profile sheet, which a sheet from the root can't cover.
        .sheet(isPresented: $adding) { AddProfileView().appEnvironment(app) }
    }

    private struct EditingID: Identifiable { let id: UUID }
}

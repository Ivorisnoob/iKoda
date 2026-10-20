import KodaCore
import SwiftUI

/// The YouTube Music account of the active profile: who is signed in, what
/// Koda has read from it, and the way in and out.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var showsSignIn = false
    @State private var showsSwitcher = false
    @State private var confirmsSignOut = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            if app.account.profile.kind == .youtube {
                account
            } else {
                signedOut
            }

            Section {
                Button {
                    showsSwitcher = true
                } label: {
                    LabeledContent {
                        Text(app.account.roster.count > 1 ? "Switch Profile" : "Profiles")
                    } label: {
                        Label("Profiles", systemImage: "person.2.fill")
                    }
                }
                Button {
                    showsSignIn = true
                } label: {
                    Label("Add YouTube Account", systemImage: "play.rectangle.fill")
                }
            } footer: {
                Text("Each profile keeps its own liked songs, history and playlists.")
            }

            if let error = app.account.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if app.account.isSignedIn {
                Section {
                    Toggle("Personalized Home", isOn: $settings.personalizedHome)
                } footer: {
                    Text("With an account signed in, Home shows that account's own shelves and recommendations. Off, Home keeps to the anonymous ones.")
                }
            }

            Section {
                Text("Koda signs your requests to YouTube Music with a session kept in this device's Keychain. It never sees your Google password, and your library on this phone is never sent to YouTube.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("YouTube Music")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSignIn) {
            YouTubeSignInView { header in
                Task { await app.account.signIn(cookieHeader: header) }
            }
        }
        .sheet(isPresented: $showsSwitcher) {
            ProfileSwitcherView().appEnvironment(app)
        }
        .confirmationDialog("Sign out of YouTube Music?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.account.signOut() }
        } message: {
            Text("The session is forgotten on this device. Your library on this phone stays as it is.")
        }
    }

    // MARK: Signed out

    @ViewBuilder
    private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Label("Bring your YouTube Music with you", systemImage: "play.rectangle.fill")
                    .font(.headline)
                Text("Sign in and Koda shows your liked songs, your playlists and a Home made for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Sign In with Google") { showsSignIn = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.vertical, 6)
        }
        Section {
            LabeledContent("Signed in", value: "No")
        } footer: {
            Text("Signing in opens Google's own page in a secure web view. The session is read straight out of it and kept in the Keychain.")
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private var account: some View {
        Section {
            accountHeader
        }
        if app.account.needsSignIn.contains(app.account.profile.id) || app.account.status == .expired {
            Section {
                Label(app.account.status == .expired
                      ? "YouTube has stopped accepting this session."
                      : "This profile has no session on this device.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Button("Sign In Again") { showsSignIn = true }
                    .buttonStyle(.borderedProminent)
            } footer: {
                Text("Your library on this phone is untouched, and Koda keeps showing what it has already read.")
            }
        } else {
            Section("Your YouTube Music Library") {
                LabeledContent("Liked songs", value: library.accountLiked.count.formatted())
                LabeledContent("Playlists", value: library.accountPlaylists.count.formatted())
                LabeledContent("Last synced", value: lastSynced)
                Button {
                    Task { await app.account.sync(force: true) }
                } label: {
                    if app.account.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    } else {
                        Text("Sync Now")
                    }
                }
                .disabled(app.account.isSyncing)
            }
        }
        Section {
            Button("Sign Out", role: .destructive) { confirmsSignOut = true }
        }
    }

    // MARK: Pieces

    private var accountHeader: some View {
        HStack(spacing: 14) {
            ProfileAvatar(profile: app.account.profile, photo: app.profile.photo(for: app.account.profile), size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.account.name.isEmpty ? "YouTube Music" : app.account.name)
                    .font(.headline)
                Text("YouTube Music")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var lastSynced: String {
        guard let date = app.account.lastSynced else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}

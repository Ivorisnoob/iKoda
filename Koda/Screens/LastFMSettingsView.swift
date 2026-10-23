import AuthenticationServices
import KodaCore
import SwiftUI

/// Last.fm on the iPhone, in Settings: connect with your own API account, then your profile,
/// whether Koda is scrobbling, what's waiting to send and what you played lately.
struct LastFMSettingsView: View {
    @Environment(LastFM.self) private var lastFM
    @Environment(\.webAuthenticationSession) private var web
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var confirmsDisconnect = false
    @FocusState private var focused: Field?

    private enum Field { case key, secret }

    var body: some View {
        Form {
            if lastFM.isConnected {
                connected
            } else {
                connect
            }
            if let error = lastFM.error {
                Section {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
            if let notice = lastFM.notice {
                Section {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Last.fm")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: lastFM.isConnected)
        .animation(.smooth, value: lastFM.isSigningIn)
        .refreshable { await lastFM.refresh() }
        .task {
            apiKey = lastFM.apiKey
            if lastFM.isConnected, lastFM.isEnabled { await lastFM.refresh() }
        }
        .confirmationDialog("Disconnect Last.fm?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect and Forget Keys", role: .destructive) { lastFM.disconnect() }
        } message: {
            Text(lastFM.queued.isEmpty
                 ? "Koda forgets your account and API keys on this iPhone. Your Last.fm history stays on Last.fm."
                 : "\(lastFM.queued.count) plays haven't been sent yet and will be lost. Your Last.fm history stays on Last.fm.")
        }
    }

    // MARK: Connected

    @ViewBuilder
    private var connected: some View {
        Section {
            HStack(spacing: 14) {
                LastFMImage(url: lastFM.profile?.avatar, size: 64, circle: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lastFM.profile?.realName.isEmpty == false ? lastFM.profile!.realName : lastFM.user)
                        .font(.title3.bold())
                    if let profile = lastFM.profile {
                        Text(LastFMUI.scrobbles(profile.playCount))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                        if let since = LastFMUI.since(profile) {
                            Text(since).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("@\(lastFM.user)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            Link(destination: LastFMUI.profileURL(lastFM.user)) {
                Label("Open Profile on Last.fm", systemImage: "safari")
            }
        }

        Section {
            Toggle(isOn: Binding(get: { lastFM.isEnabled }, set: { lastFM.setEnabled($0) })) {
                SettingLabel("Scrobble", systemImage: "dot.radiowaves.left.and.right", tint: .red)
            }
            HStack {
                Text(LastFMUI.status(lastFM))
                    .foregroundStyle(lastFM.isPaused ? .orange : .secondary)
                Spacer()
                if lastFM.isBusy {
                    ProgressView()
                } else if lastFM.isEnabled, !lastFM.isPaused {
                    Button("Sync Now") { Task { await lastFM.refresh() } }
                }
            }
            .font(.subheadline)
        } footer: {
            Text("A song counts once you've heard half of it, or four minutes, whichever is first. Videos aren't scrobbled. Plays wait on this iPhone while you're offline and send in order later, with the time you played them.")
        }

        let live = lastFM.refreshedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        ForEach(LastFMUI.days(lastFM.recent.filter { live || !$0.isNowPlaying }), id: \.title) { day in
            Section(day.title) {
                ForEach(day.tracks) { LastFMTrackRow(track: $0) }
            }
        }

        Section {
            Button("Disconnect…", role: .destructive) { confirmsDisconnect = true }
        } footer: {
            Text("Signed in as \(lastFM.user). Koda keeps your API keys and session in this iPhone's Keychain only; they aren't in backups.")
        }
    }

    // MARK: Connecting

    @ViewBuilder
    private var connect: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.red.gradient, in: .rect(cornerRadius: 14, style: .continuous))
                Text("Scrobble to Last.fm").font(.title3.bold())
                Text("Keep a record of what you play in Koda on your Last.fm profile. Koda never sees your password: you sign in on Last.fm's own page.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }

        if lastFM.isSigningIn {
            Section {
                Label("Waiting for you to approve Koda on Last.fm", systemImage: "hourglass")
                Button("I've Approved Koda") { Task { try? await lastFM.finishSignIn() } }
                    .disabled(lastFM.isBusy)
                Button("Open Last.fm Again") { signIn(restart: true) }
                    .disabled(lastFM.isBusy)
                Button("Start Over", role: .destructive) { lastFM.setEnabled(false) }
            } footer: {
                Text("The approval page is good for an hour.")
            }
        } else {
            Section {
                Link(destination: LastFMUI.createAccountURL) {
                    Label("Create a Last.fm API Account", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("1. Your API Account")
            } footer: {
                Text("It's free. Any name and description will do, and leave Callback URL empty. Each person uses their own, so no keys ship with Koda.")
            }

            Section {
                TextField("API Key", text: $apiKey)
                    .focused($focused, equals: .key)
                    .submitLabel(.next)
                    .onSubmit { focused = .secret }
                SecureField("Shared Secret", text: $secret)
                    .focused($focused, equals: .secret)
                    .submitLabel(.go)
                    .onSubmit { signIn(restart: false) }
            } header: {
                Text("2. Its Keys")
            } footer: {
                Text("Both are on the page Last.fm shows after you create the account.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())

            Section {
                Button {
                    signIn(restart: false)
                } label: {
                    HStack {
                        Text("Connect to Last.fm").fontWeight(.semibold)
                        Spacer()
                        if lastFM.isBusy { ProgressView() }
                    }
                }
                .disabled(!canConnect || lastFM.isBusy)
            } footer: {
                Text("Last.fm opens for you to approve Koda. Close it when you're done and Koda finishes connecting.")
            }
        }
    }

    private var canConnect: Bool {
        LastFMProtocol.isCredential(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            && LastFMProtocol.isCredential(secret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func signIn(restart: Bool) {
        focused = nil
        Task {
            guard let url = try? await (restart ? lastFM.restartSignIn() : lastFM.beginSignIn(apiKey: apiKey, secret: secret)) else { return }
            secret = ""
            await LastFMUI.approve(url, lastFM: lastFM, web: web)
        }
    }
}

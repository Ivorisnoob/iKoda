import AuthenticationServices
import KodaCore
import SwiftUI

/// Last.fm on the Mac, as a page in the sidebar: once connected, the account and what Koda is
/// sending on the left and the listener's recent plays on the right; before that, the three
/// steps to connect laid out in one card.
struct MacLastFMView: View {
    @Environment(LastFM.self) private var lastFM

    var body: some View {
        MacPage(spacing: 28) {
            MacPageTitle(title: "Last.fm", subtitle: "Scrobbling") {
                if lastFM.isConnected {
                    if lastFM.isBusy { ProgressView().controlSize(.small) }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await lastFM.refresh() } }
                        .buttonStyle(.glass)
                        .disabled(lastFM.isBusy || !lastFM.isEnabled || lastFM.isPaused)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Send waiting plays and refresh (⌘R)")
                }
            }
            if lastFM.isConnected {
                MacLastFMConnected()
            } else {
                MacLastFMConnect()
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Last.fm")
        .animation(.smooth, value: lastFM.isConnected)
        .task { if lastFM.isConnected, lastFM.isEnabled { await lastFM.refresh() } }
    }
}

// MARK: - Connected

private struct MacLastFMConnected: View {
    @Environment(LastFM.self) private var lastFM
    @State private var confirmsDisconnect = false
    @State private var width: CGFloat = 1000

    var body: some View {
        // The account beside the history; above it in a narrow window.
        let wide = width > 760
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            account
                .frame(width: wide ? 300 : nil, alignment: .leading)
            history
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, MacMetrics.gutter)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .confirmationDialog("Disconnect Last.fm?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect and Forget Keys", role: .destructive) { lastFM.disconnect() }
        } message: {
            Text(lastFM.queued.isEmpty
                 ? "Koda forgets your account and API keys on this Mac. Your Last.fm history stays on Last.fm."
                 : "\(lastFM.queued.count) plays haven't been sent yet and will be lost. Your Last.fm history stays on Last.fm.")
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                LastFMImage(url: lastFM.profile?.avatar, size: 88, circle: true)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastFM.profile?.realName.isEmpty == false ? lastFM.profile!.realName : lastFM.user)
                        .font(.title2.bold())
                    Text("@\(lastFM.user)").font(.callout).foregroundStyle(.secondary)
                }
                if let profile = lastFM.profile {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(profile.playCount.formatted())
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .foregroundStyle(.red)
                            .contentTransition(.numericText())
                        Text(profile.playCount == 1 ? "scrobble" : "scrobbles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let since = LastFMUI.since(profile) {
                        Text(since).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Toggle(isOn: Binding(get: { lastFM.isEnabled }, set: { lastFM.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scrobble").font(.body.weight(.semibold))
                    Text(LastFMUI.status(lastFM))
                        .font(.caption)
                        .foregroundStyle(lastFM.isPaused ? .orange : .secondary)
                }
            }
            .toggleStyle(.switch)

            if let error = lastFM.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let notice = lastFM.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A song counts once you've heard half of it, or four minutes. Videos aren't scrobbled. Offline plays wait on this Mac and send in order later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Link(destination: LastFMUI.profileURL(lastFM.user)) {
                    Label("Profile", systemImage: "safari")
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Disconnect…", role: .destructive) { confirmsDisconnect = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private var history: some View {
        let live = lastFM.refreshedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        let days = LastFMUI.days(lastFM.recent.filter { live || !$0.isNowPlaying })
        VStack(alignment: .leading, spacing: 20) {
            MacSectionTitle(title: "Recent scrobbles",
                            subtitle: lastFM.refreshedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" })
            if days.isEmpty {
                ContentUnavailableView("Nothing Scrobbled Yet", systemImage: "music.note.list",
                                       description: Text("Songs you play in Koda appear here once they count."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
            ForEach(days, id: \.title) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.leading, 8)
                    ForEach(Array(day.tracks.enumerated()), id: \.element.id) { index, track in
                        MacHoverRow(index: index) { LastFMTrackRow(track: track, coverSize: 40) }
                    }
                }
            }
        }
    }
}

/// A list row with the Mac's alternating stripe and a light under the pointer.
private struct MacHoverRow<Content: View>: View {
    let index: Int
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : (index.isMultiple(of: 2) ? 0.03 : 0)))
            }
            .onHover { hovering = $0 }
    }
}

// MARK: - Connecting

private struct MacLastFMConnect: View {
    @Environment(LastFM.self) private var lastFM
    @Environment(\.webAuthenticationSession) private var web
    @State private var apiKey = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.red.gradient, in: .rect(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scrobble to Last.fm").font(.title2.bold())
                    Text("Keep a record of what you play in Koda on your Last.fm profile. Koda never sees your password: you approve it on Last.fm's own page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if lastFM.isSigningIn {
                waiting
            } else {
                step(1, "Create your API account",
                     "It's free. Any name and description will do; leave Callback URL empty. Each person uses their own, so no keys ship with Koda.") {
                    Link(destination: LastFMUI.createAccountURL) {
                        Label("Create API Account", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.glass)
                }
                step(2, "Enter its keys", "Both are on the page Last.fm shows after you create the account.") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("API key").foregroundStyle(.secondary)
                            TextField("32 letters and digits", text: $apiKey)
                        }
                        GridRow {
                            Text("Shared secret").foregroundStyle(.secondary)
                            SecureField("32 letters and digits", text: $secret)
                                .onSubmit(connect)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .frame(maxWidth: 440)
                }
                step(3, "Approve Koda", "Last.fm opens in a window. Approve Koda there and close it; Koda finishes connecting by itself.") {
                    HStack(spacing: 10) {
                        Button(action: connect) {
                            Label("Connect to Last.fm", systemImage: "link")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!canConnect || lastFM.isBusy)
                        if lastFM.isBusy { ProgressView().controlSize(.small) }
                    }
                }
            }

            if let error = lastFM.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("Your API keys and session stay in this Mac's Keychain, out of backups. Turn scrobbling off any time; pausing listening history pauses it too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 640, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .padding(.horizontal, MacMetrics.gutter)
        .task { apiKey = lastFM.apiKey }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Waiting for you to approve Koda on Last.fm", systemImage: "hourglass")
                .font(.headline)
            Text("The approval page is good for an hour.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("I've Approved Koda") { Task { try? await lastFM.finishSignIn() } }
                    .buttonStyle(.glassProminent)
                Button("Open Last.fm Again") { open(restart: true) }
                    .buttonStyle(.glass)
                Button("Start Over", role: .destructive) { lastFM.setEnabled(false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
            .disabled(lastFM.isBusy)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: .circle)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                content()
            }
        }
    }

    private var canConnect: Bool {
        LastFMProtocol.isCredential(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            && LastFMProtocol.isCredential(secret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func connect() {
        guard canConnect else { return }
        open(restart: false)
    }

    private func open(restart: Bool) {
        Task {
            guard let url = try? await (restart ? lastFM.restartSignIn() : lastFM.beginSignIn(apiKey: apiKey, secret: secret)) else { return }
            secret = ""
            await LastFMUI.approve(url, lastFM: lastFM, web: web)
        }
    }
}

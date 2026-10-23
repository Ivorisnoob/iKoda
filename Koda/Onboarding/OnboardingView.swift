import KodaCore
import SwiftUI

/// The first launch: a welcome, the YouTube Music account (signing in, and whether plays go to
/// its history), then taste setup. From Settings, only taste setup. Each page is pushed on one
/// stack, so Back works as everywhere else, and every step can be skipped.
struct OnboardingView: View {
    enum Start: Identifiable {
        case welcome, taste
        var id: Self { self }
    }

    enum Page: Hashable {
        case account, artists, genres, deck, done
    }

    let start: Start
    @State private var taste: TasteModel
    @State private var preview: TastePreview
    @State private var path: [Page] = []
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(start: Start, music: YouTubeMusic, library: Library) {
        self.start = start
        _taste = State(initialValue: TasteModel(music: music, library: library))
        _preview = State(initialValue: TastePreview(music: music))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .welcome: WelcomePage { path.append(.account) }
                case .taste: TasteArtistsPage(taste: taste, next: { path.append(.genres) }, skip: finish)
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .account:
                    OnboardingAccountPage { path.append(.artists) }
                case .artists:
                    TasteArtistsPage(taste: taste, next: { path.append(.genres) }, skip: finish)
                case .genres:
                    TasteGenresPage(taste: taste, next: {
                        path.append(taste.picked.isEmpty && taste.genres.isEmpty ? .done : .deck)
                    }, skip: finish)
                case .deck:
                    TasteDeckPage(taste: taste, preview: preview, next: { path.append(.done) }, skip: finish)
                case .done:
                    OnboardingDonePage(taste: taste, isFirstLaunch: start == .welcome, finish: finish)
                }
            }
        }
        // Artists start loading on the welcome page, so the grid is ready when it's reached.
        .task { await taste.start() }
        .interactiveDismissDisabled(start == .welcome)
        .frame(minWidth: Platform.isMac ? 560 : nil, minHeight: Platform.isMac ? 680 : nil)
    }

    private func finish() {
        preview.stop()
        app.settings.hasSeenOnboarding = true
        // Home was built before these picks; build it again from them.
        Task { await app.loadHome(app.home) }
        app.onboarding = nil
        dismiss()
    }
}

// MARK: - Welcome

/// "Welcome to Koda", as Apple's own apps greet: the icon, a title, what the app does in three
/// lines, and one way on.
private struct WelcomePage: View {
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                VStack(spacing: 18) {
                    Image("KodaIcon")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 104, height: 104)
                        .accessibilityHidden(true)
                    Text("Welcome to Koda")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 26) {
                    WelcomeFeature(systemImage: "sparkles.rectangle.stack", title: "Made From What You Love",
                                   detail: "Your Mix and Quick picks come from your own listening, starting with a few artists you pick.")
                    WelcomeFeature(systemImage: "person.crop.circle.badge.checkmark", title: "Your YouTube Music",
                                   detail: "Sign in to bring your likes, playlists and Home, and keep them in step.")
                    WelcomeFeature(systemImage: "person.2", title: "A Profile for Everyone",
                                   detail: "Each person gets their own library, history and Home on this \(Platform.isMac ? "Mac" : "iPhone").")
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            OnboardingButton("Continue", action: next)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct WelcomeFeature: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Account

/// Signing in to YouTube Music, or not now. Signed in, the choice about the account's YouTube
/// history is made here, in plain view, rather than left to a default nobody saw.
private struct OnboardingAccountPage: View {
    let next: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let profile = app.roster.active
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: profile.isSignedIn ? "checkmark.circle.fill" : "music.note.house.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                Text(profile.isSignedIn ? "You're Signed In" : "Bring Your YouTube Music")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(profile.isSignedIn
                     ? "Your likes, playlists and saved albums are coming in now, and stay in step from here on."
                     : "Sign in to bring your likes, playlists and Home to Koda. Google's own page handles the sign-in; Koda never sees your password.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if profile.isSignedIn {
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            ProfileAvatar(profile: profile, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName).font(.headline)
                                Text(profile.handle ?? "YouTube Music").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        Divider().padding(.leading, 16)
                        Toggle(isOn: Binding(get: { app.roster.active.sendsPlaysToYouTube },
                                             set: { on in app.roster.update(profile.id) { $0.sendsPlaysToYouTube = on } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Plays to YouTube History")
                                Text("Songs you play for 15 seconds appear in your YouTube Music history and shape its recommendations.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .background(.fill.quinary, in: .rect(cornerRadius: 24, style: .continuous))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: profile.isSignedIn)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 6) {
                if profile.isSignedIn {
                    OnboardingButton("Continue", action: next)
                } else {
                    NavigationLink {
                        YouTubeSignInView(into: profile.id)
                    } label: {
                        Text("Sign In to YouTube Music").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .padding(.horizontal, 32)
                    Button("Not Now", action: next)
                        .padding(.bottom, 8)
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: 520)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Done

private struct OnboardingDonePage: View {
    let taste: TasteModel
    let isFirstLaunch: Bool
    let finish: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)
            Text(isFirstLaunch ? "You're All Set" : "Taste Updated")
                .font(.largeTitle.bold())
            Text(summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .safeAreaBar(edge: .bottom) {
            OnboardingButton(isFirstLaunch ? "Start Listening" : "Done", action: finish)
        }
        .navigationBarBackButtonHidden()
        .onAppear { appeared = true }
    }

    private var summary: String {
        var parts: [String] = []
        if !taste.picked.isEmpty { parts.append(taste.picked.count == 1 ? "1 artist" : "\(taste.picked.count) artists") }
        if !taste.genres.isEmpty { parts.append(taste.genres.count == 1 ? "1 genre" : "\(taste.genres.count) genres") }
        if taste.kept > 0 { parts.append(taste.kept == 1 ? "1 song" : "\(taste.kept) songs") }
        guard !parts.isEmpty else { return "Home fills in as you listen. You can pick artists any time in Settings." }
        return "Home is built from \(ListFormatter.localizedString(byJoining: parts)), and gets better the more you listen."
    }
}

// MARK: - Shared

/// The one prominent way on at the foot of a page.
struct OnboardingButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
    }
}

/// A page's title and what it asks, at the top of its scroll view.
struct OnboardingHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }
}

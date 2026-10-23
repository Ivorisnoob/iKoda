import KodaCore
import SwiftUI
import WebKit

/// Signing in to YouTube Music on Google's own page. Koda never sees the password: once Google
/// sends the browser back to YouTube Music, the youtube.com cookies it set are the session.
///
/// Each sign-in gets a fresh, private website store, so a second account can never silently be
/// the first one again, and nothing of Google's stays behind in the app afterwards.
struct YouTubeSignInView: View {
    /// The profile to sign in; nil adds the account as a profile of its own.
    let into: UUID?
    var onFinish: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var phase = Phase.browsing
    @State private var attempt = 0

    enum Phase: Equatable {
        case browsing, finishing, failed(String)
    }

    var body: some View {
        ZStack {
            SignInWebView(attempt: attempt, progress: $progress) { cookies in
                guard phase == .browsing else { return false }
                guard AccountCookies.isSignedIn(cookies) else { return false }
                finish(with: cookies)
                return true
            }
            .opacity(phase == .browsing ? 1 : 0.3)
            .allowsHitTesting(phase == .browsing)

            switch phase {
            case .browsing:
                EmptyView()
            case .finishing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Bringing in your YouTube Music…").font(.headline)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Sign In", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        phase = .browsing
                        attempt += 1
                    }
                    .buttonStyle(.glass)
                }
                .background(.background)
            }
        }
        .overlay(alignment: .top) {
            if phase == .browsing, progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
        .animation(.smooth, value: phase)
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label("accounts.google.com", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Secure Google sign-in page")
            }
        }
    }

    private func finish(with cookies: [HTTPCookie]) {
        phase = .finishing
        Task {
            do {
                try await app.completeSignIn(cookies: cookies, into: into)
                onFinish()
                dismiss()
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "YouTube Music didn't accept the sign-in. Try again in a moment.")
            }
        }
    }
}

/// The youtube.com session in a cookie jar, by the exact cookie names Google sets on sign-in.
enum AccountCookies {
    /// Exact names, not substrings: "SID" would also match SAPISID and __Secure-3PSID, which a
    /// jar with no real session can still carry.
    static let required = ["SID", "HSID", "SSID", "APISID", "SAPISID"]

    /// Only youtube.com's: mid-sign-in, google.com's jar also holds a SAPISID, and that one signs
    /// in as "logged in but anonymous", which every YouTube endpoint then refuses.
    static func youtube(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { $0.domain.hasSuffix("youtube.com") }
    }

    static func isSignedIn(_ cookies: [HTTPCookie]) -> Bool {
        let names = Set(youtube(cookies).map(\.name))
        return required.allSatisfy(names.contains)
    }
}

/// Google's page in a WebKit view of its own, reporting the cookie jar each time a page finishes
/// loading on YouTube Music; `onCookies` returns true once it has what it needs.
private struct SignInWebView: UIViewRepresentable {
    let attempt: Int
    @Binding var progress: Double
    let onCookies: ([HTTPCookie]) -> Bool

    static let start = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Google turns away sign-ins from browsers it doesn't recognise; Safari's own identity
        // is what this view is.
        view.customUserAgent = Platform.isMac
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        context.coordinator.observe(view)
        context.coordinator.loadedAttempt = attempt
        view.load(URLRequest(url: Self.start))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedAttempt != attempt else { return }
        // Try Again: a clean jar and Google's first page.
        context.coordinator.loadedAttempt = attempt
        context.coordinator.done = false
        let store = view.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            view.load(URLRequest(url: Self.start))
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        coordinator.progressObservation = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        var loadedAttempt = 0
        var done = false
        var progressObservation: NSKeyValueObservation?

        init(_ parent: SignInWebView) {
            self.parent = parent
        }

        func observe(_ view: WKWebView) {
            progressObservation = view.observe(\.estimatedProgress, options: [.new]) { @Sendable [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor in self?.parent.progress = value }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, webView.url?.host()?.hasSuffix("youtube.com") == true else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            Task {
                let cookies = await store.allCookies()
                guard !done else { return }
                if parent.onCookies(cookies) { done = true }
            }
        }
    }
}

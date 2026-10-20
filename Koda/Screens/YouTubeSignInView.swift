import KodaCore
import SwiftUI
import UIKit
import WebKit

/// Signing in to YouTube Music, in Koda's own WebKit view.
///
/// YouTube Music gives a third-party client no sign-in API: the `WEB_REMIX`
/// client stopped accepting OAuth, and `ASWebAuthenticationSession` cannot
/// hand back the session cookies a music client needs. WebKit is the only
/// way to hold the very session the web client holds, and it is the
/// browser's own API for doing so — the page is Google's, the password is
/// typed into Google's page, and Koda never sees it.
///
/// The session is taken out of the cookie store as it is written
/// (`WKHTTPCookieStoreObserver`), so it is there the moment Google has signed
/// the person in: no waiting, no polling, and nothing pasted by hand.
struct YouTubeSignInView: View {
    @Environment(\.dismiss) private var dismiss
    /// The session, as a cookie header, once there is one.
    let onSession: (String) -> Void
    @State private var isSignedIn = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in with the Google account you use on YouTube Music.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                SignInWebView { header in
                    guard let header else { return }
                    isSignedIn = true
                    onSession(header)
                }
            }
            .navigationTitle("Sign in to YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // The session is taken; the sheet's work is done.
        .onChange(of: isSignedIn) { _, done in
            if done { dismiss() }
        }
        .frame(minWidth: Platform.isMac ? 520 : nil, minHeight: Platform.isMac ? 600 : nil)
    }
}

/// Google's sign-in page, with the session read out of the cookie store as
/// it is written.
private struct SignInWebView: UIViewRepresentable {
    /// The session, once the cookie store holds one.
    let onSession: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A jar of its own, thrown away with the view: nothing of the
        // sign-in is left on the device.
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        context.coordinator.start(web: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// WebKit's own callbacks, and the reading of the cookie store.
    ///
    /// The class is main-actor isolated, because the web view is; the two
    /// protocol witnesses WebKit calls are not, so they step back onto the
    /// main actor — WebKit delivers both on the main thread.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onSession: @MainActor (String?) -> Void
        /// The session has been taken; nothing else is read.
        private let taken = Flag()
        private weak var web: WKWebView?
        private var dataStore: WKWebsiteDataStore?

        init(onSession: @escaping @MainActor (String?) -> Void) {
            self.onSession = onSession
        }

        /// Google's sign-in page, and the observer that watches the jar.
        func start(web: WKWebView) {
            self.web = web
            let dataStore = web.configuration.websiteDataStore
            self.dataStore = dataStore
            dataStore.httpCookieStore.add(self)
            let url = Self.loginURL
            // The jar is emptied first: Google's page signs in whoever the jar
            // already holds, so a second account would silently be the first
            // one again. The stored sessions are untouched by this.
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                 modifiedSince: .distantPast) { [weak self] in
                Task { @MainActor in self?.web?.load(URLRequest(url: url)) }
            }
        }

        func stop() {
            dataStore?.httpCookieStore.remove(self)
        }

        /// A cookie was written: the session may be here now.
        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            MainActor.assumeIsolated { self.read(cookieStore) }
        }

        /// The page finished loading: the last of the sign-in steps may have
        /// written the session.
        nonisolated func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { self.read(web.configuration.websiteDataStore.httpCookieStore) }
        }

        private func read(_ store: WKHTTPCookieStore) {
            // Copied out, so the closure below holds nothing but values that
            // may cross a thread.
            let onSession = self.onSession
            let taken = self.taken
            store.getAllCookies { cookies in
                // Only YouTube's own cookies: mid-sign-in the page sits on
                // accounts.google.com, whose jar also carries a SAPISID, and
                // taking that one signs in as "logged in but anonymous".
                guard let header = YouTubeSession.header(from: cookies),
                      YouTubeSession.isComplete(header) else { return }
                guard taken.take() else { return }
                Task { @MainActor in onSession(header) }
            }
        }

        /// Google's own sign-in page for YouTube, the one the web client uses.
        static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!
    }
}

/// A flag that may be taken once, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// True the first time only.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

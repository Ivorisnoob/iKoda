import UIKit
import UniformTypeIdentifiers

/// "Koda" in the share sheet: takes the link being shared (a video from the YouTube app, a page
/// from Safari) and hands it to the app, which opens it as it would any link (`AppModel.open`).
/// It draws nothing of its own: the sheet goes and Koda comes forward.
///
/// An extension has no API for opening its own app. `UIApplication.open` on the application
/// found up the responder chain is what every share extension that does it uses, and what works
/// from iOS 18 on (the older `openURL:` selector stopped then).
final class ShareViewController: UIViewController {
    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task {
            if let link = await sharedLink(), let handoff = Self.handoff(for: link) {
                openApp(handoff)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// `koda://open?url=<the link>`.
    private static func handoff(for link: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "koda"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        return components.url
    }

    /// The shared web link: a URL attachment, or the first link in shared text (YouTube's app
    /// shares both).
    private func sharedLink() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, Self.isWeb(url) { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                  let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { continue }
            let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: Self.isWeb)
            if let match { return match }
        }
        return nil
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}

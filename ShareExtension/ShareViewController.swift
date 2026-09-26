import UIKit
import UniformTypeIdentifiers

/// "Share → ReadAnythingAloud": saves the page to the app's inbox and confirms, without opening the app.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let icon = UIImageView()
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        // The system presents share extensions in its own sheet; keep it plain and let the card carry the message.
        view.backgroundColor = .systemBackground
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        icon.image = UIImage(systemName: "text.badge.plus")
        icon.tintColor = UIColor(named: "AccentColor") ?? UIColor(red: 0.78, green: 0.47, blue: 0.41, alpha: 1)
        icon.preferredSymbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentMode = .scaleAspectFit

        label.text = "Adding to ReadAnythingAloud…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.card.alpha = 1
            self.card.transform = .identity
        }
        Task { await collectAndSave() }
    }

    private func collectAndSave() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var page = SharedPage()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let dict = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
               let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                page.url = page.url ?? (results["url"] as? String).flatMap(URL.init(string:))
                page.title = results["title"] as? String
                if let html = results["html"] as? String, !html.isEmpty { page.html = html }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                page.url = page.url ?? url
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                // Apps often share a link as text ("Title https://…").
                if page.url == nil, let url = Self.firstWebURL(in: text) {
                    page.url = url
                } else {
                    page.text = text
                }
            }
        }

        let saved: Bool
        if page.url != nil || !(page.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved = (try? ShareInbox.post(page)) != nil
        } else {
            saved = false
        }
        show(saved ? "Added. It'll be ready in ReadAnythingAloud." : "Nothing to add from this item.",
             symbol: saved ? "checkmark.circle.fill" : "exclamationmark.circle")
        try? await Task.sleep(for: .milliseconds(saved ? 900 : 1600))
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func show(_ message: String, symbol: String) {
        label.text = message
        icon.image = UIImage(systemName: symbol)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private static func firstWebURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}

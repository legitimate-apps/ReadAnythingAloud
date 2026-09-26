import Foundation
import Observation
import ReadAloudKit
import SwiftUI
import UniformTypeIdentifiers

/// App-wide state: the library, the article being added, and the reading session (which outlives the reader
/// screen so audio keeps playing while you browse the library).
@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let settings: VoiceSettings

    var selection: UUID? {
        didSet { if let selection, selection != session?.article.id { open(selection) } }
    }
    private(set) var session: ReadingSession?
    private(set) var adding: PendingAdd?
    var failure: AddFailure?
    var isPresentingAdd = false
    var isPresentingSettings = false
    /// Set when the user chooses "Open page" for a blocked article; drives the interactive web sheet.
    var webPage: WebPageRequest?

    struct PendingAdd: Equatable {
        var url: URL?
        var label: String
    }

    struct AddFailure: Identifiable {
        let id = UUID()
        var url: URL?
        var error: Error
        var canOpenPage: Bool { url != nil && !(url?.isFileURL ?? true) }
        var canReadWholePage: Bool {
            if case .notReadable = error as? ExtractionError { return true }
            return false
        }
    }

    struct WebPageRequest: Identifiable {
        let id = UUID()
        var url: URL
    }

    init(library: LibraryStore? = nil, settings: VoiceSettings? = nil) {
        self.library = library ?? LibraryStore()
        self.settings = settings ?? .shared
        warmUpVoice()
        restoreLastArticle()
    }

    private static let lastArticleKey = "library.lastOpenedArticle"

    /// Reopens the article that was open when the app last quit (positioned at its saved progress, not playing).
    private func restoreLastArticle() {
        guard let raw = UserDefaults.standard.string(forKey: Self.lastArticleKey), let id = UUID(uuidString: raw),
              library.items.contains(where: { $0.id == id }) else { return }
        selection = id
    }

    /// Loading Kokoro takes ~25 s per launch (Core ML specializes the models for the Neural Engine), so start it
    /// in the background as soon as the app opens rather than when the listener presses play.
    private func warmUpVoice() {
        guard settings.preferredVoice.engine == .kokoro, KokoroEngine.isDownloaded else { return }
        let settings = settings
        Task(priority: .utility) { await settings.prepareKokoro() }
    }

    // MARK: - Opening

    func open(_ id: UUID) {
        guard session?.article.id != id else { return }
        guard let article = library.article(id) else { return }
        session?.close()
        session = ReadingSession(article: article, library: library, settings: settings)
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastArticleKey)
        if selection != id { selection = id }
    }

    func closeSession() {
        session?.close()
        session = nil
        UserDefaults.standard.removeObject(forKey: Self.lastArticleKey)
    }

    func delete(_ ids: Set<UUID>) {
        if let current = session?.article.id, ids.contains(current) {
            closeSession()
            selection = nil
        }
        library.delete(ids)
    }

    // MARK: - Adding

    /// Adds whatever the user dropped, pasted or shared: a URL, a `.webloc`, an HTML or text file, or plain text.
    func add(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.webURL(from: trimmed) {
            add(url: url)
        } else if trimmed.count > 40 {
            add(text: trimmed, title: nil)
        } else {
            failure = AddFailure(url: nil, error: ExtractionError.invalidURL)
        }
    }

    /// Adds a web page. An article already in the library is just opened unless `refresh` asks to fetch it again.
    func add(url: URL, mode: ExtractionMode = .article, refresh: Bool = false) {
        if url.isFileURL {
            addFile(url)
            return
        }
        if mode == .article, !refresh, let existing = library.existingItem(for: url) {
            selection = existing.id
            return
        }
        adding = PendingAdd(url: url, label: url.host(percentEncoded: false) ?? url.absoluteString)
        Task {
            defer { adding = nil }
            do {
                let article = try await ArticleExtractor.shared.extract(url: url, mode: mode)
                store(article)
            } catch {
                failure = AddFailure(url: url, error: error)
            }
        }
    }

    func add(text: String, title: String?) {
        let paragraphs = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return }
        let resolvedTitle = title ?? String(paragraphs[0].prefix(80))
        let body = (title == nil && paragraphs[0].count <= 120 && paragraphs.count > 1) ? Array(paragraphs.dropFirst()) : paragraphs
        let article = Article(title: resolvedTitle, siteName: "Pasted text",
                              blocks: body.map { Block(kind: .paragraph, text: $0) })
        let saved = library.add(article)
        selection = saved.id
    }

    func addFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .internetShortcut) == true || url.pathExtension.lowercased() == "webloc",
           let target = Self.webloc(url) {
            add(url: target)
            return
        }
        if type?.conforms(to: .html) == true || ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            adding = PendingAdd(url: nil, label: url.lastPathComponent)
            Task {
                defer { adding = nil }
                do {
                    let article = try await ArticleExtractor.shared.extract(html: html, baseURL: url)
                    selection = library.add(article).id
                } catch {
                    failure = AddFailure(url: nil, error: error)
                }
            }
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            add(text: text, title: url.deletingPathExtension().lastPathComponent)
            return
        }
        failure = AddFailure(url: nil, error: ExtractionError.notHTML(url.pathExtension))
    }

    /// Extracts from the interactive page sheet after the user logged in or passed a check.
    func addFromWebView(_ webView: WKWebViewBox, url: URL?) async -> Error? {
        do {
            let article: Article
            do {
                article = try await ArticleExtractor.shared.extract(from: webView.webView, sourceURL: url, mode: .article)
            } catch ExtractionError.notReadable {
                article = try await ArticleExtractor.shared.extract(from: webView.webView, sourceURL: url, mode: .wholePage)
            }
            store(article)
            return nil
        } catch {
            return error
        }
    }

    /// Saves an extracted article and shows it. Re-adding a page replaces the stored copy (keeping its place in
    /// the library and the listening progress), so an open reader is reopened on the fresh text.
    private func store(_ article: Article) {
        let saved = library.add(article)
        if session?.article.id == saved.id {
            closeSession()
            open(saved.id)
        }
        selection = saved.id
    }

    // MARK: - Drops and URL schemes

    func handleOpenURL(_ url: URL) {
        if url.scheme == "readanythingaloud" {
            // readanythingaloud://add?url=https://…
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let target = components?.queryItems?.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) {
                add(url: target)
            }
            return
        }
        url.isFileURL ? addFile(url) : add(url: url)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in url.isFileURL ? self.addFile(url) : self.add(url: url) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in self.add(input: text) }
                }
                return true
            }
        }
        return false
    }

    static func webURL(from text: String) -> URL? {
        let candidate = text.components(separatedBy: .whitespacesAndNewlines).first { $0.contains(".") || $0.hasPrefix("http") } ?? text
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }
        if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
            return url
        }
        // Bare domains: "example.com/story"
        if candidate.range(of: #"^[\w-]+(\.[\w-]+)+(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + candidate)
        }
        // A URL embedded in shared text ("Look at this https://…").
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let match = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        if let url = match?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return nil
    }

    static func webloc(_ url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String else { return nil }
        return URL(string: string)
    }
}

import WebKit

/// Sendable-agnostic holder so views can hand a WKWebView to the model.
@MainActor
final class WKWebViewBox {
    let webView: WKWebView
    init(_ webView: WKWebView) { self.webView = webView }
}

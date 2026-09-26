import Foundation
import WebKit

public enum ExtractionError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case loadFailed(String)
    case httpStatus(Int)
    case timedOut
    /// The page loaded but has no readable article (paywall, bot check, app shell, index page).
    case notReadable(reason: String?, pageTitle: String?, wordCount: Int)
    case notHTML(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "That doesn't look like a web address."
        case .loadFailed(let message): "The page couldn't be loaded: \(message)"
        case .httpStatus(let code) where code == 404 || code == 410:
            "There's no page at this address (HTTP \(code)). Check the link."
        case .httpStatus(let code) where code == 401 || code == 403:
            "The site refused to serve the page (HTTP \(code)). It may want you to sign in or pass a check."
        case .httpStatus(429): "The site is limiting requests right now (HTTP 429). Try again in a minute."
        case .httpStatus(let code) where code >= 500: "The site had a server error (HTTP \(code)). Try again later."
        case .httpStatus(let code): "The site answered with an error (HTTP \(code))."
        case .timedOut: "The page took too long to load."
        case .notReadable(let reason, _, _):
            if let reason { "This page looks blocked (“\(reason)”). It may need a login or a human check." }
            else { "No readable article was found on this page." }
        case .notHTML(let type): "This link isn't a web page (\(type))."
        }
    }

    /// Whether opening the page interactively (to log in or pass a check) might help.
    public var mightNeedInteraction: Bool {
        switch self {
        case .notReadable, .httpStatus(401), .httpStatus(403), .httpStatus(429): true
        default: false
        }
    }
}

/// How to pull the article out of a loaded page.
public enum ExtractionMode: String, Sendable {
    /// Mozilla Readability; fails if it finds no article.
    case article
    /// Everything in `<body>` — the user's explicit "read the whole page anyway".
    case wholePage
}

/// Loads pages in a WKWebView (so JavaScript-rendered sites and the user's cookies work) and extracts the article
/// with Mozilla Readability plus a DOM walker that emits typed blocks.
@MainActor
public final class ArticleExtractor: NSObject {
    public static let shared = ArticleExtractor()

    private static let scripts: String = {
        let bundle = Bundle.module
        let names = ["Readability", "ArticleWalker"]
        return names.compactMap { name in
            bundle.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n;\n")
    }()

    /// Hosts web views on iOS so WebKit doesn't throttle a detached view's timers.
    public var hostView: (() -> PlatformView?)?

    public override init() {}

    /// A web view configured for extraction; also used by the interactive "open page" sheet so the user's login
    /// lands in the same website data store.
    public static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        #if os(iOS)
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        #endif
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400), configuration: config)
        webView.customUserAgent = userAgent
        return webView
    }

    /// Safari's user agent, so sites serve their normal markup rather than a bot or embedded-view variant.
    static let userAgent: String = {
        #if os(iOS)
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        #else
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        #endif
    }()

    /// Loads `url` off-screen and extracts its article.
    public func extract(url: URL, mode: ExtractionMode = .article, timeout: TimeInterval = 30) async throws -> Article {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            throw ExtractionError.invalidURL
        }
        let webView = Self.makeWebView()
        if let rules = await Self.extractionRules() {
            webView.configuration.userContentController.add(rules)
        }
        let host = hostView?()
        attach(webView, to: host)
        defer { webView.removeFromSuperview() }

        let loader = PageLoader(webView: webView)
        try await loader.load(url, timeout: timeout, finishWhenReadable: true)
        await settle(webView)
        return try await extract(from: webView, sourceURL: webView.url ?? url, mode: mode)
    }

    /// Content rules for the off-screen extraction view: images, media and fonts are never looked at (the walker
    /// reads `src` attributes, not pixels), and skipping them is most of a heavy page's load time. The
    /// interactive page sheet doesn't use these rules, so the user sees the page normally.
    private static var compiledRules: WKContentRuleList?
    private static var didCompileRules = false

    static func extractionRules() async -> WKContentRuleList? {
        if didCompileRules { return compiledRules }
        didCompileRules = true
        let json = #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
        compiledRules = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "ReadAloud.extraction.v1", encodedContentRuleList: json)
        return compiledRules
    }

    /// Extracts from raw HTML (a dropped `.html` file or shared page source).
    public func extract(html: String, baseURL: URL?, mode: ExtractionMode = .article) async throws -> Article {
        let webView = Self.makeWebView()
        attach(webView, to: hostView?())
        defer { webView.removeFromSuperview() }
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let loader = PageLoader(webView: webView)
        try await loader.loadHTML(html, baseURL: baseURL, timeout: 20)
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return try await extract(from: webView, sourceURL: baseURL, mode: mode)
    }

    /// Extracts from a web view that already shows the page (the interactive sheet after the user logged in).
    public func extract(from webView: WKWebView, sourceURL: URL?, mode: ExtractionMode) async throws -> Article {
        let raw = try await webView.evaluateJavaScript(Self.scripts + "\n;window.__readAloudExtract(\"\(mode.rawValue)\");")
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw ExtractionError.loadFailed("The page couldn't be read.")
        }
        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: data)
        if let error = payload.error { throw ExtractionError.loadFailed(error) }
        let usable = mode == .wholePage ? payload.wordCount > 0 : (payload.ok && payload.usedReadability == true)
        guard usable else {
            throw ExtractionError.notReadable(reason: payload.reason, pageTitle: payload.pageTitle ?? payload.title,
                                              wordCount: payload.wordCount)
        }
        return payload.article(sourceURL: sourceURL)
    }

    private func attach(_ webView: WKWebView, to host: PlatformView?) {
        guard let host else { return }
        #if os(iOS)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        host.insertSubview(webView, at: 0)
        #else
        webView.alphaValue = 0
        host.addSubview(webView, positioned: .below, relativeTo: nil)
        #endif
    }

    /// Gives client-rendered pages a moment to fill in: waits until the body's text length stops growing.
    private func settle(_ webView: WKWebView) async {
        var last = -1
        for _ in 0..<12 {
            let length = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText.length : 0")) as? Int ?? 0
            if length > 500 && length == last { return }
            last = length
            try? await Task.sleep(for: .milliseconds(350))
        }
    }
}

#if os(iOS)
import UIKit
public typealias PlatformView = UIView
#else
import AppKit
public typealias PlatformView = NSView
#endif

/// Bridges WKNavigationDelegate callbacks to async/await.
@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var httpStatus: Int?
    private var mimeType: String?
    private var finishWhenReadable = false
    private var readinessPoll: Task<Void, Never>?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// - Parameter finishWhenReadable: return once the document is parsed and its text has stopped growing,
    ///   instead of waiting for every subresource (ads, trackers, analytics) to finish loading.
    func load(_ url: URL, timeout: TimeInterval, finishWhenReadable: Bool = false) async throws {
        self.finishWhenReadable = finishWhenReadable
        try await run(timeout: timeout) {
            var request = URLRequest(url: url)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            if url.isFileURL {
                self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                self.webView.load(request)
            }
        }
        if let status = httpStatus, status >= 400 { throw ExtractionError.httpStatus(status) }
        if let mime = mimeType, !(mime.contains("html") || mime.contains("xml") || mime.hasPrefix("text/")) {
            throw ExtractionError.notHTML(mime)
        }
    }

    func loadHTML(_ html: String, baseURL: URL?, timeout: TimeInterval) async throws {
        try await run(timeout: timeout) { self.webView.loadHTMLString(html, baseURL: baseURL) }
    }

    private func run(timeout: TimeInterval, start: () -> Void) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        let watchdog = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.webView.stopLoading()
            self?.finish(ExtractionError.timedOut)
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                continuation = cont
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webView.stopLoading()
                self?.finish(CancellationError())
            }
        }
    }

    private func finish(_ error: Error?) {
        readinessPoll?.cancel()
        readinessPoll = nil
        guard let cont = continuation else { return }
        continuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            httpStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            mimeType = navigationResponse.response.mimeType
            if let mime = mimeType, mime == "application/pdf" || mime.hasPrefix("audio/") || mime.hasPrefix("video/") {
                return .cancel
            }
            // An error status decides the outcome on its own; don't wait for the error page's ads and scripts.
            if let status = httpStatus, status >= 400 {
                finish(nil)
                return .cancel
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard finishWhenReadable, readinessPoll == nil else { return }
        readinessPoll = Task { @MainActor [weak self, weak webView] in
            var last = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let webView, !Task.isCancelled else { return }
                let probe = try? await webView.evaluateJavaScript(
                    "document.readyState + '|' + (document.body ? document.body.innerText.length : 0)") as? String
                let parts = probe?.split(separator: "|") ?? []
                guard parts.count == 2, parts[0] != "loading", let length = Int(parts[1]) else { continue }
                if length > 1_000, length == last {
                    self?.finish(nil)
                    return
                }
                last = length
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(Self.mapped(error, mime: mimeType))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(Self.mapped(error, mime: mimeType))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(ExtractionError.loadFailed("The page crashed while loading."))
    }

    private static func mapped(_ error: Error, mime: String?) -> Error {
        let ns = error as NSError
        // WebKit reports "frame load interrupted" when we cancel a non-HTML response.
        if ns.domain == "WebKitErrorDomain", ns.code == 102, let mime { return ExtractionError.notHTML(mime) }
        return ExtractionError.loadFailed(ns.localizedDescription)
    }
}

/// JSON produced by `ArticleWalker.js`.
struct ExtractionPayload: Decodable {
    struct RawBlock: Decodable {
        struct Run: Decodable {
            var t: String
            var b: Bool?
            var i: Bool?
            var c: Bool?
            var a: String?
        }
        var k: String
        var level: Int?
        var ordered: Bool?
        var number: Int?
        var depth: Int?
        var runs: [Run]?
        var text: String?
        var src: String?
        var alt: String?
    }

    var ok: Bool
    var usedReadability: Bool?
    var title: String?
    var byline: String?
    var siteName: String?
    var excerpt: String?
    var lang: String?
    var leadImage: String?
    var publishedTime: String?
    var pageTitle: String?
    var blocks: [RawBlock]
    var wordCount: Int
    var reason: String?
    var preview: Bool?
    var error: String?

    func article(sourceURL: URL?) -> Article {
        let converted: [Block] = blocks.compactMap { raw in
            let runs = (raw.runs ?? []).map {
                InlineRun(text: $0.t, bold: $0.b ?? false, italic: $0.i ?? false, code: $0.c ?? false,
                          link: $0.a.flatMap(URL.init(string:)))
            }
            switch raw.k {
            case "h": return Block(kind: .heading(level: min(max(raw.level ?? 2, 1), 6)), runs: runs)
            case "p": return Block(kind: .paragraph, runs: runs)
            case "li": return Block(kind: .listItem(ordered: raw.ordered ?? false, number: raw.number ?? 1,
                                                    depth: min(raw.depth ?? 0, 4)), runs: runs)
            case "quote": return Block(kind: .quote, runs: runs)
            case "caption": return Block(kind: .caption, runs: runs)
            case "code": return raw.text.map { Block(kind: .code, runs: [InlineRun(text: $0, code: true)]) }
            case "img": return Block(kind: .image(url: raw.src.flatMap(URL.init(string:)), alt: raw.alt), runs: [])
            case "hr": return Block(kind: .separator, runs: [])
            default: return nil
            }
        }
        let clean: (String?) -> String? = { s in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let resolvedTitle = Self.bestTitle(clean(title) ?? clean(pageTitle), siteName: clean(siteName), blocks: converted)
        return Article(
            sourceURL: sourceURL,
            title: resolvedTitle ?? sourceURL?.host() ?? "Untitled",
            byline: clean(byline).map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 },
            siteName: clean(siteName),
            language: clean(lang).map { $0.replacingOccurrences(of: "_", with: "-") },
            excerpt: clean(excerpt),
            leadImageURL: leadImage.flatMap(URL.init(string:)),
            publishedTime: clean(publishedTime),
            blocks: Self.dropDuplicateLeadImage(converted, lead: leadImage),
            isPreview: preview == true ? true : nil
        )
    }

    /// Prefers the article's own leading heading when the page title is that heading plus site branding
    /// ("The River Rises | Example News"), and otherwise strips a trailing " | Site" / " - Site".
    static func bestTitle(_ title: String?, siteName: String?, blocks: [Block]) -> String? {
        guard let title else { return nil }
        let leading = blocks.prefix(4).first { if case .heading = $0.kind { true } else { false } }
        if let heading = leading?.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
           heading.count >= 6, heading.count < title.count, title.localizedCaseInsensitiveContains(heading) {
            return heading
        }
        for separator in [" | ", " - ", " — ", " – ", " :: ", " · "] {
            if let range = title.range(of: separator, options: .backwards) {
                let tail = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if let siteName, tail.localizedCaseInsensitiveCompare(siteName) == .orderedSame, !head.isEmpty {
                    return head
                }
            }
        }
        return title
    }

    /// Readability often keeps the hero image; keep it (it's content) but drop consecutive duplicate images.
    static func dropDuplicateLeadImage(_ blocks: [Block], lead: String?) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            if case .image(let url, _) = block.kind, let last = out.last, case .image(let prev, _) = last.kind, url == prev {
                continue
            }
            out.append(block)
        }
        return out
    }
}

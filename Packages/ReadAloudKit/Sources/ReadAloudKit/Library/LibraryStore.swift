import Foundation
import Observation

/// Where the reader left off in an article.
public struct ReadingProgress: Codable, Sendable, Hashable {
    public var sentence: Int
    public var word: Int?
    public var fraction: Double
    public var updatedAt: Date

    public init(sentence: Int, word: Int?, fraction: Double, updatedAt: Date = Date()) {
        self.sentence = sentence
        self.word = word
        self.fraction = fraction
        self.updatedAt = updatedAt
    }
}

extension ReadingProgress {
    /// The same place in a re-extracted version of the document. Sentence indices shift whenever extraction
    /// changes (a merged footnote, a dropped banner), so the sentence is found again by its text — the match
    /// nearest the old position — falling back to the same relative text offset.
    public func remapped(from old: ReadingDocument, to new: ReadingDocument) -> ReadingProgress {
        guard old.sentences.indices.contains(sentence), !new.sentences.isEmpty else { return self }
        let key = { (doc: ReadingDocument, i: Int) in
            doc.string(for: doc.sentences[i].range).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let target = key(old, sentence)
        let matches = target.isEmpty ? [] : new.sentences.indices.filter { key(new, $0) == target }
        let oldOffset = Double(old.sentences[sentence].range.location) / Double(max(1, (old.text as NSString).length))
        let newIndex: Int
        if let nearest = matches.min(by: { abs($0 - sentence) < abs($1 - sentence) }) {
            newIndex = nearest
        } else {
            newIndex = new.sentenceIndex(atOffset: Int(oldOffset * Double((new.text as NSString).length))) ?? 0
        }
        var word: Int?
        if let oldWord = self.word, old.sentences[sentence].wordIndices.contains(oldWord), !matches.isEmpty {
            let within = oldWord - old.sentences[sentence].wordIndices.lowerBound
            let range = new.sentences[newIndex].wordIndices
            word = range.isEmpty ? nil : min(range.lowerBound + within, range.upperBound - 1)
        } else {
            word = new.sentences[newIndex].wordIndices.first
        }
        return ReadingProgress(sentence: newIndex, word: word, fraction: fraction, updatedAt: updatedAt)
    }
}

/// Lightweight row for the library list (the full article is loaded on open).
public struct ArticleSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var host: String?
    public var sourceURL: URL?
    public var leadImageURL: URL?
    public var excerpt: String?
    public var wordCount: Int
    public var addedAt: Date
    public var progress: ReadingProgress?

    public var isFinished: Bool { (progress?.fraction ?? 0) >= 1 }
}

/// Persists articles as JSON files in Application Support, with a small index for the list.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var items: [ArticleSummary] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.library.decode([ArticleSummary].self, from: data) else {
            items = []
            return
        }
        // Drop index rows whose article file vanished.
        items = decoded.filter { FileManager.default.fileExists(atPath: articleURL($0.id).path) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder.library.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func articleURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Adds an article (or replaces the existing one for the same URL, keeping its progress and id).
    @discardableResult
    public func add(_ article: Article) -> Article {
        var article = article
        var progress: ReadingProgress?
        if let url = article.sourceURL, let existing = existingItem(for: url) {
            article.id = existing.id
            article.addedAt = existing.addedAt
            progress = existing.progress
            if let saved = progress, let previous = self.article(existing.id) {
                progress = saved.remapped(from: DocumentBuilder.build(previous), to: DocumentBuilder.build(article))
            }
            items.removeAll { $0.id == existing.id }
        }
        if let data = try? JSONEncoder.library.encode(article) {
            try? data.write(to: articleURL(article.id), options: .atomic)
        }
        let item = ArticleSummary(id: article.id, title: article.title, host: article.displayHost,
                               sourceURL: article.sourceURL, leadImageURL: article.leadImageURL ?? firstImage(article),
                               excerpt: article.excerpt, wordCount: article.wordCount, addedAt: article.addedAt,
                               progress: progress)
        items.insert(item, at: 0)
        saveIndex()
        return article
    }

    private func firstImage(_ article: Article) -> URL? {
        for block in article.blocks {
            if case .image(let url, _) = block.kind, let url { return url }
        }
        return nil
    }

    public func article(_ id: UUID) -> Article? {
        guard let data = try? Data(contentsOf: articleURL(id)) else { return nil }
        return try? JSONDecoder.library.decode(Article.self, from: data)
    }

    public func item(_ id: UUID) -> ArticleSummary? { items.first { $0.id == id } }

    public func existingItem(for url: URL) -> ArticleSummary? {
        items.first { $0.sourceURL.map { Self.sameArticle($0, url) } ?? false }
    }

    public func updateProgress(_ id: UUID, _ progress: ReadingProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = progress
        saveIndex()
    }

    public func delete(_ ids: some Sequence<UUID>) {
        for id in ids {
            try? FileManager.default.removeItem(at: articleURL(id))
            items.removeAll { $0.id == id }
        }
        saveIndex()
    }

    /// Same page ignoring fragments, tracking parameters and a trailing slash.
    public static func sameArticle(_ a: URL, _ b: URL) -> Bool {
        canonical(a) == canonical(b)
    }

    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { item in
            !(item.name.hasPrefix("utm_") || ["fbclid", "gclid", "ref", "ref_src", "smid", "mc_cid", "mc_eid"].contains(item.name))
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.host = parts.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        parts.scheme = "https"
        var s = parts.string ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

extension JSONEncoder {
    static let library: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let library: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

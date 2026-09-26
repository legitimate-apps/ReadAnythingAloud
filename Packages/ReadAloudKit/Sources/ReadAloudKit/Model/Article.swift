import Foundation

/// An extracted, persisted article: metadata plus typed content blocks.
public struct Article: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var sourceURL: URL?
    public var title: String
    public var byline: String?
    public var siteName: String?
    /// BCP-47 language tag reported by the page or detected from the text.
    public var language: String?
    public var excerpt: String?
    public var leadImageURL: URL?
    public var publishedTime: String?
    public var blocks: [Block]
    public var addedAt: Date
    /// True when the page is paywalled and only its free teaser was extracted.
    public var isPreview: Bool?

    public init(
        id: UUID = UUID(),
        sourceURL: URL? = nil,
        title: String,
        byline: String? = nil,
        siteName: String? = nil,
        language: String? = nil,
        excerpt: String? = nil,
        leadImageURL: URL? = nil,
        publishedTime: String? = nil,
        blocks: [Block],
        addedAt: Date = Date(),
        isPreview: Bool? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.language = language
        self.excerpt = excerpt
        self.leadImageURL = leadImageURL
        self.publishedTime = publishedTime
        self.blocks = blocks
        self.addedAt = addedAt
        self.isPreview = isPreview
    }

    /// Number of words across speakable blocks — used for list metadata and time estimates.
    public var wordCount: Int {
        blocks.filter(\.kind.isSpeakable).reduce(0) { total, block in
            total + block.plainText.split(whereSeparator: { $0.isWhitespace }).count
        }
    }

    /// Host shown in the library ("nytimes.com").
    public var displayHost: String? {
        siteName ?? sourceURL?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "")
    }
}

/// One structural unit of an article.
public struct Block: Codable, Sendable, Hashable {
    public var kind: Kind
    public var runs: [InlineRun]

    public init(kind: Kind, runs: [InlineRun]) {
        self.kind = kind
        self.runs = runs
    }

    public init(kind: Kind, text: String) {
        self.init(kind: kind, runs: [InlineRun(text: text)])
    }

    public var plainText: String { runs.map(\.text).joined() }

    public enum Kind: Codable, Sendable, Hashable {
        case heading(level: Int)
        case paragraph
        case listItem(ordered: Bool, number: Int, depth: Int)
        case quote
        case code
        case image(url: URL?, alt: String?)
        case caption
        /// Byline / site / date line under the title. Shown, not spoken.
        case byline
        case separator

        /// Whether the block is read aloud. Code, images and separators are shown but skipped.
        public var isSpeakable: Bool {
            switch self {
            case .heading, .paragraph, .listItem, .quote, .caption: true
            case .code, .image, .byline, .separator: false
            }
        }
    }
}

/// A run of text with inline styling.
public struct InlineRun: Codable, Sendable, Hashable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var link: URL?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: URL? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
    }

    enum CodingKeys: String, CodingKey { case text, bold, italic, code, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
        link = try c.decodeIfPresent(URL.self, forKey: .link)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if bold { try c.encode(bold, forKey: .bold) }
        if italic { try c.encode(italic, forKey: .italic) }
        if code { try c.encode(code, forKey: .code) }
        try c.encodeIfPresent(link, forKey: .link)
    }
}

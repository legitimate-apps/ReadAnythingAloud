import Foundation

/// A UTF-16 range, the currency of TextKit (`NSRange`) but `Codable` and `Sendable`.
public struct TextRange: Codable, Sendable, Hashable, CustomStringConvertible {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ ns: NSRange) {
        self.init(location: ns.location, length: ns.length)
    }

    public var upperBound: Int { location + length }
    public var ns: NSRange { NSRange(location: location, length: length) }

    public func contains(_ offset: Int) -> Bool { offset >= location && offset < upperBound }

    public func offset(by delta: Int) -> TextRange { TextRange(location: location + delta, length: length) }

    public var description: String { "[\(location), \(upperBound))" }
}

/// The flattened, indexed form of an `Article` that the reader view renders and the player speaks.
///
/// All ranges are UTF-16 offsets into `text`. Blocks are separated by a single `"\n"`. Image blocks are a
/// single U+FFFC object-replacement character the view swaps for an attachment. List items carry a
/// display-only marker ("•  ", "3.  ") that sits outside every sentence range, so it is never spoken.
public struct ReadingDocument: Sendable {
    public struct BlockLayout: Sendable, Hashable {
        public var index: Int
        public var kind: Block.Kind
        /// Full range of the block in `text`, including any list marker.
        public var range: TextRange
        /// Range of the block's content (marker excluded).
        public var contentRange: TextRange
        /// Sentences belonging to this block (empty for unspoken blocks).
        public var sentenceIndices: Range<Int>
        /// Inline style runs, as ranges into `text`.
        public var styles: [StyleSpan]
    }

    public struct StyleSpan: Sendable, Hashable {
        public var range: TextRange
        public var bold: Bool
        public var italic: Bool
        public var code: Bool
        public var link: URL?
    }

    public struct Sentence: Sendable, Hashable {
        public var index: Int
        public var blockIndex: Int
        /// Range of the sentence in `text` (trimmed of surrounding whitespace).
        public var range: TextRange
        /// Words of the sentence, as indices into `ReadingDocument.words`.
        public var wordIndices: Range<Int>
        /// Text handed to the speech engine. Same UTF-16 length as `range`, with unspeakable spans
        /// (citation markers, bare URLs) blanked to spaces so local offsets map 1:1 to the display.
        public var speechText: String
        /// Whether this sentence ends its block (the player adds a paragraph-sized pause after it).
        public var endsBlock: Bool
    }

    public struct Word: Sendable, Hashable {
        public var index: Int
        public var sentenceIndex: Int
        public var range: TextRange
    }

    public let articleID: UUID
    public let text: String
    public let blocks: [BlockLayout]
    public let sentences: [Sentence]
    public let words: [Word]
    public let language: String?

    public init(articleID: UUID, text: String, blocks: [BlockLayout], sentences: [Sentence], words: [Word], language: String?) {
        self.articleID = articleID
        self.text = text
        self.blocks = blocks
        self.sentences = sentences
        self.words = words
        self.language = language
    }

    /// Substring for a range.
    public func string(for range: TextRange) -> String {
        (text as NSString).substring(with: range.ns)
    }

    /// Words of a sentence, with ranges relative to the sentence's start (i.e. into `speechText`).
    public func localWordRanges(ofSentence index: Int) -> [TextRange] {
        let sentence = sentences[index]
        return sentence.wordIndices.map { words[$0].range.offset(by: -sentence.range.location) }
    }

    /// The word whose range contains (or, failing that, is nearest after) a text offset.
    public func wordIndex(atOffset offset: Int) -> Int? {
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid].range.upperBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first word ending after `offset`. If the tap landed in the gap before it, use it anyway.
        if lo > 0, !words[lo].range.contains(offset), words[lo - 1].range.upperBound >= offset - 1 {
            return lo - 1
        }
        return lo
    }

    /// The sentence containing a text offset, or the nearest following sentence.
    public func sentenceIndex(atOffset offset: Int) -> Int? {
        guard !sentences.isEmpty else { return nil }
        var lo = 0, hi = sentences.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sentences[mid].range.upperBound <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First sentence of the block after the one containing `sentence` (for paragraph skipping).
    public func nextBlockSentence(after sentence: Int) -> Int? {
        let block = sentences[sentence].blockIndex
        return sentences[(sentence + 1)...].first(where: { $0.blockIndex != block })?.index
    }

    /// First sentence of the current block, or of the previous block when already at its start.
    public func previousBlockSentence(before sentence: Int) -> Int {
        let block = sentences[sentence].blockIndex
        let blockStart = sentences[..<sentence].last(where: { $0.blockIndex != block }).map { $0.index + 1 } ?? 0
        if blockStart < sentence { return blockStart }
        guard sentence > 0 else { return 0 }
        let prevBlock = sentences[sentence - 1].blockIndex
        return sentences[..<sentence].first(where: { $0.blockIndex == prevBlock })?.index ?? 0
    }

    public var totalWordCount: Int { words.count }
}

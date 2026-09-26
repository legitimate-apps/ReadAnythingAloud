import Foundation
import NaturalLanguage

/// Builds a `ReadingDocument` from an `Article`: flattens blocks into one string, segments speakable blocks
/// into sentences and words, and prepares engine-facing speech text.
public enum DocumentBuilder {
    /// The object-replacement character used as an image placeholder in the flattened text.
    public static let attachmentCharacter = "\u{FFFC}"

    public static func build(_ article: Article) -> ReadingDocument {
        let language = article.language.flatMap { $0.isEmpty ? nil : $0 } ?? detectLanguage(article)
        let nlLanguage = language.map { NLLanguage(rawValue: String($0.prefix(2))) }

        var text = ""
        var utf16Length = 0
        var layouts: [ReadingDocument.BlockLayout] = []
        var sentences: [ReadingDocument.Sentence] = []
        var words: [ReadingDocument.Word] = []

        for (blockIndex, block) in documentBlocks(for: article).enumerated() {
            if blockIndex > 0 {
                text += "\n"
                utf16Length += 1
            }
            let blockStart = utf16Length
            let marker = listMarker(for: block.kind)
            text += marker
            utf16Length += marker.utf16.count
            let contentStart = utf16Length

            var styles: [ReadingDocument.StyleSpan] = []
            let content: String
            if case .image = block.kind {
                content = attachmentCharacter
            } else {
                var assembled = ""
                var cursor = contentStart
                let isCode = block.kind == .code
                var normalized = block.runs.map { normalizeWhitespace($0.text, preserveNewlines: isCode) }
                if !isCode {
                    // Trim the block's outer whitespace and collapse spaces across run boundaries.
                    if let first = normalized.firstIndex(where: { !$0.isEmpty }) {
                        normalized[first] = String(normalized[first].drop(while: { $0 == " " }))
                    }
                    if let last = normalized.lastIndex(where: { !$0.isEmpty }) {
                        while normalized[last].hasSuffix(" ") { normalized[last].removeLast() }
                    }
                }
                for (run, rawText) in zip(block.runs, normalized) {
                    var runText = rawText
                    if !isCode, assembled.hasSuffix(" ") || assembled.isEmpty {
                        runText = String(runText.drop(while: { $0 == " " }))
                    }
                    let len = runText.utf16.count
                    if len > 0, run.bold || run.italic || run.code || run.link != nil {
                        styles.append(.init(range: TextSpan(location: cursor, length: len),
                                            bold: run.bold, italic: run.italic, code: run.code, link: run.link))
                    }
                    assembled += runText
                    cursor += len
                }
                content = assembled
            }
            text += content
            utf16Length += content.utf16.count

            let contentRange = TextSpan(location: contentStart, length: content.utf16.count)
            let firstSentence = sentences.count
            if block.kind.isSpeakable {
                segment(content, offset: contentStart, blockIndex: blockIndex, language: nlLanguage,
                        sentences: &sentences, words: &words)
                if firstSentence < sentences.count {
                    sentences[sentences.count - 1].endsBlock = true
                }
            }
            layouts.append(.init(index: blockIndex, kind: block.kind,
                                 range: TextSpan(location: blockStart, length: utf16Length - blockStart),
                                 contentRange: contentRange,
                                 sentenceIndices: firstSentence..<sentences.count,
                                 styles: styles))
        }
        return ReadingDocument(articleID: article.id, text: text, blocks: layouts, sentences: sentences,
                               words: words, language: language)
    }

    /// Title heading and byline line, followed by the article blocks with a duplicated leading title removed.
    static func documentBlocks(for article: Article) -> [Block] {
        var result: [Block] = []
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            result.append(Block(kind: .heading(level: 1), text: title))
        }
        let meta = [article.byline, article.displayHost]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let uniqueMeta = meta.filter { seen.insert($0.lowercased()).inserted }
        if !uniqueMeta.isEmpty {
            result.append(Block(kind: .byline, text: uniqueMeta.joined(separator: " · ")))
        }
        var body = article.blocks.filter { block in
            if case .image = block.kind { return true }
            if block.kind == .separator { return true }
            return !block.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let first = body.first(where: { $0.kind != .separator }), case .heading = first.kind,
           simplify(first.plainText) == simplify(title) {
            body.removeAll { $0 == first }
        }
        result.append(contentsOf: attachingStrayFootnotes(body))
        return result
    }

    /// Some sites (Paul Graham's essays, older blogs) put a footnote marker like "[5]" on its own line after the
    /// paragraph it annotates. Shown alone it reads as a stray paragraph, so fold it into the preceding text block.
    static func attachingStrayFootnotes(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            let text = block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if block.kind == .paragraph, isFootnoteMarker(text), let last = out.indices.last, out[last].kind.isSpeakable {
                var runs = block.runs
                if let i = runs.indices.first { runs[i].text = " " + runs[i].text.drop(while: \.isWhitespace) }
                out[last].runs.append(contentsOf: runs)
                continue
            }
            out.append(block)
        }
        return out
    }

    static func isFootnoteMarker(_ text: String) -> Bool {
        text.range(of: #"^(\[\w{1,3}\]\s*)+$"#, options: .regularExpression) != nil
    }

    static func listMarker(for kind: Block.Kind) -> String {
        guard case let .listItem(ordered, number, depth) = kind else { return "" }
        let indent = String(repeating: "\t", count: max(0, depth))
        return indent + (ordered ? "\(number).\t" : "•\t")
    }

    // MARK: - Segmentation

    static func segment(_ content: String, offset: Int, blockIndex: Int, language: NLLanguage?,
                        sentences: inout [ReadingDocument.Sentence], words: inout [ReadingDocument.Word]) {
        let speech = blankUnspeakable(content)
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = content
        if let language { sentenceTokenizer.setLanguage(language) }

        var sentenceRanges: [Range<String.Index>] = []
        sentenceTokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            sentenceRanges.append(range)
            return true
        }
        if sentenceRanges.isEmpty { sentenceRanges = [content.startIndex..<content.endIndex] }

        let wordTokenizer = NLTokenizer(unit: .word)
        if let language { wordTokenizer.setLanguage(language) }
        let speechNS = speech as NSString

        for range in splitOverlong(sentenceRanges, in: content) {
            let trimmed = trim(range, in: content)
            guard !trimmed.isEmpty else { continue }
            let local = NSRange(trimmed, in: content)
            let sentenceText = speechNS.substring(with: local)

            wordTokenizer.string = sentenceText
            var localWords: [NSRange] = []
            wordTokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { wr, _ in
                let token = sentenceText[wr]
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    localWords.append(NSRange(wr, in: sentenceText))
                }
                return true
            }
            guard !localWords.isEmpty else { continue }

            let sentenceIndex = sentences.count
            let firstWord = words.count
            for w in localWords {
                words.append(.init(index: words.count, sentenceIndex: sentenceIndex,
                                   range: TextSpan(location: offset + local.location + w.location, length: w.length)))
            }
            sentences.append(.init(index: sentenceIndex, blockIndex: blockIndex,
                                   range: TextSpan(location: offset + local.location, length: local.length),
                                   wordIndices: firstWord..<words.count,
                                   speechText: sentenceText,
                                   endsBlock: false))
        }
    }

    /// Splits sentences longer than ~320 characters at clause punctuation so the first audio arrives quickly and
    /// highlighting granularity stays useful on run-on sentences.
    static func splitOverlong(_ ranges: [Range<String.Index>], in content: String) -> [Range<String.Index>] {
        let limit = 320
        var out: [Range<String.Index>] = []
        for range in ranges {
            var pending = range
            while content.distance(from: pending.lowerBound, to: pending.upperBound) > limit {
                let window = content[pending]
                let target = content.index(pending.lowerBound, offsetBy: limit / 2)
                var best: String.Index?
                var bestDistance = Int.max
                for separator in ["; ", ": ", " — ", ", "] {
                    var searchStart = window.startIndex
                    while let found = window[searchStart...].range(of: separator) {
                        let cut = found.upperBound
                        let d = abs(content.distance(from: target, to: cut))
                        let minPiece = 60
                        if content.distance(from: pending.lowerBound, to: cut) > minPiece,
                           content.distance(from: cut, to: pending.upperBound) > minPiece, d < bestDistance {
                            best = cut
                            bestDistance = d
                        }
                        searchStart = found.upperBound
                    }
                    if best != nil { break }
                }
                guard let cut = best else { break }
                out.append(pending.lowerBound..<cut)
                pending = cut..<pending.upperBound
            }
            out.append(pending)
        }
        return out
    }

    static func trim(_ range: Range<String.Index>, in s: String) -> Range<String.Index> {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, s[lower].isWhitespace { lower = s.index(after: lower) }
        while upper > lower, s[s.index(before: upper)].isWhitespace { upper = s.index(before: upper) }
        return lower..<upper
    }

    // MARK: - Text cleanup

    private static let unspeakablePatterns: [NSRegularExpression] = [
        // Citation markers: [1], [12], [a], [citation needed], [note 3]
        try! NSRegularExpression(pattern: #"\[(?:\d{1,3}|[a-z]|citation needed|note \d+|edit)\]"#, options: [.caseInsensitive]),
        // Bare URLs
        try! NSRegularExpression(pattern: #"\bhttps?://\S+"#, options: []),
    ]

    /// Replaces unspeakable spans with spaces of identical UTF-16 length.
    static func blankUnspeakable(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for regex in unspeakablePatterns {
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                ns.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        return ns as String
    }

    static func normalizeWhitespace(_ s: String, preserveNewlines: Bool) -> String {
        if preserveNewlines { return s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace || ch == "\u{00AD}" {
                if ch == "\u{00AD}" { continue } // soft hyphen
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    static func simplify(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func detectLanguage(_ article: Article) -> String? {
        let sample = article.blocks.filter(\.kind.isSpeakable).prefix(20).map(\.plainText).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(article.title + " " + sample)
        return recognizer.dominantLanguage?.rawValue
    }
}

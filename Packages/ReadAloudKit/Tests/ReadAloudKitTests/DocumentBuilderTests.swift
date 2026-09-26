import Foundation
import Testing
@testable import ReadAloudKit

@Suite struct DocumentBuilderTests {
    func article(_ blocks: [Block], title: String = "A Title", byline: String? = nil) -> Article {
        Article(title: title, byline: byline, language: "en", blocks: blocks)
    }

    @Test func titleIsSpokenAndBylineIsNot() {
        let doc = DocumentBuilder.build(article([Block(kind: .paragraph, text: "Body text here.")], byline: "Jane Doe"))
        #expect(doc.blocks.count == 3)
        #expect(doc.blocks[1].kind == .byline)
        #expect(doc.blocks[1].sentenceIndices.isEmpty)
        #expect(doc.sentences.map { doc.string(for: $0.range) } == ["A Title", "Body text here."])
    }

    @Test func duplicateLeadingHeadingIsDropped() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .heading(level: 1), text: "A  title!"),
            Block(kind: .paragraph, text: "Hello."),
        ]))
        #expect(doc.sentences.map { doc.string(for: $0.range) } == ["A Title", "Hello."])
    }

    @Test func sentencesAndWordsHaveExactRanges() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .paragraph, text: "Dr. Smith arrived at 5 p.m. on Tuesday. He left — quickly!"),
        ], title: ""))
        #expect(doc.sentences.count == 2)
        #expect(doc.string(for: doc.sentences[0].range) == "Dr. Smith arrived at 5 p.m. on Tuesday.")
        #expect(doc.string(for: doc.sentences[1].range) == "He left — quickly!")
        let words = doc.words.map { doc.string(for: $0.range) }
        #expect(words.contains("Smith"))
        #expect(!words.contains("—"))
        #expect(doc.sentences[1].endsBlock)
        #expect(!doc.sentences[0].endsBlock)
        // Every word lies inside its sentence.
        for w in doc.words {
            let s = doc.sentences[w.sentenceIndex].range
            #expect(w.range.location >= s.location && w.range.upperBound <= s.upperBound)
        }
    }

    @Test func listMarkersAreDisplayedButNotSpoken() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .listItem(ordered: true, number: 3, depth: 0), text: "Third item."),
            Block(kind: .listItem(ordered: false, number: 0, depth: 1), text: "Nested bullet."),
        ], title: ""))
        #expect(doc.text == "3.\tThird item.\n\t•\tNested bullet.")
        #expect(doc.sentences.map { doc.string(for: $0.range) } == ["Third item.", "Nested bullet."])
    }

    @Test func imagesAndCodeAreShownButSkipped() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .paragraph, text: "Before."),
            Block(kind: .image(url: URL(string: "https://x.test/a.png"), alt: "A cat"), runs: []),
            Block(kind: .code, text: "let x = 1\nprint(x)"),
            Block(kind: .paragraph, text: "After."),
        ], title: ""))
        #expect(doc.text == "Before.\n\u{FFFC}\nlet x = 1\nprint(x)\nAfter.")
        #expect(doc.sentences.count == 2)
        #expect(doc.blocks[1].contentRange.length == 1)
    }

    @Test func citationsAndURLsAreBlankedInSpeechText() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .paragraph, text: "It was true[12] as shown at https://example.com/x today."),
        ], title: ""))
        let s = doc.sentences[0]
        #expect(s.speechText.utf16.count == s.range.length)
        #expect(!s.speechText.contains("12"))
        #expect(!s.speechText.contains("example"))
        let words = doc.words.map { doc.string(for: $0.range) }
        #expect(words == ["It", "was", "true", "as", "shown", "at", "today"])
    }

    @Test func inlineStylesAndWhitespaceAcrossRuns() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .paragraph, runs: [
                InlineRun(text: "  Read "), InlineRun(text: " this ", bold: true), InlineRun(text: "\n now. "),
            ]),
        ], title: ""))
        #expect(doc.text == "Read this now.")
        let style = doc.blocks[0].styles.first
        #expect(style?.bold == true)
        #expect(style.map { doc.string(for: $0.range) } == "this ")
    }

    @Test func overlongSentencesAreSplitAtClauses() {
        let clause = "this clause goes on for a good while without stopping at all"
        let long = Array(repeating: clause, count: 8).joined(separator: ", ") + "."
        let doc = DocumentBuilder.build(article([Block(kind: .paragraph, text: long)], title: ""))
        #expect(doc.sentences.count > 1)
        #expect(doc.sentences.allSatisfy { $0.range.length <= 340 })
        let rejoined = doc.sentences.map { doc.string(for: $0.range) }.joined(separator: " ")
        #expect(rejoined == long)
    }

    @Test func lookupHelpers() {
        let doc = DocumentBuilder.build(article([
            Block(kind: .paragraph, text: "One two. Three four."),
            Block(kind: .paragraph, text: "Five six."),
        ], title: ""))
        let three = doc.words.first { doc.string(for: $0.range) == "Three" }!
        #expect(doc.wordIndex(atOffset: three.range.location + 1) == three.index)
        #expect(doc.sentenceIndex(atOffset: three.range.location) == 1)
        #expect(doc.nextBlockSentence(after: 0) == 2)
        #expect(doc.previousBlockSentence(before: 1) == 0)
        #expect(doc.previousBlockSentence(before: 2) == 0)
        #expect(doc.previousBlockSentence(before: 0) == 0)
    }
}

import Foundation
import Testing
@testable import ReadAloudKit

@MainActor
@Suite(.serialized) struct ExtractionTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    }

    @Test func extractsTypedBlocksFromArticle() async throws {
        let article = try await ArticleExtractor().extract(url: try fixture("article"))
        #expect(article.title == "The River Rises")
        #expect(article.byline?.contains("Jane Q. Reporter") == true)
        #expect(article.language?.hasPrefix("en") == true)

        let kinds = article.blocks.map(\.kind)
        #expect(kinds.contains { if case .image(let url, let alt) = $0 { url?.lastPathComponent == "river.jpg" && alt == "Flooded street" } else { false } })
        #expect(kinds.contains(.caption))
        #expect(kinds.contains(.heading(level: 2)))
        #expect(kinds.contains(.quote))
        #expect(kinds.contains(.code))
        #expect(kinds.contains(.listItem(ordered: false, number: 1, depth: 0)) || kinds.contains { if case .listItem(false, _, 0) = $0 { true } else { false } })
        #expect(kinds.contains { if case .listItem(false, _, 1) = $0 { true } else { false } })
        #expect(kinds.contains { if case .listItem(true, 3, 0) = $0 { true } else { false } })

        let text = article.blocks.map(\.plainText).joined(separator: "\n")
        #expect(!text.contains("cookies"))
        #expect(!text.contains("tracking"))
        #expect(!text.contains("Privacy"))
        // Footnote superscripts are dropped.
        #expect(text.contains("anything like it."))
        #expect(!text.contains("it.1"))

        let emphasis = article.blocks.flatMap(\.runs).first { $0.italic }
        #expect(emphasis?.text == "never")
        let strong = article.blocks.flatMap(\.runs).first { $0.bold }
        #expect(strong?.text == "faster than in 2019")
    }

    @Test func paywalledPageFailsGracefully() async throws {
        do {
            _ = try await ArticleExtractor().extract(url: try fixture("paywall"))
            Issue.record("Expected a notReadable error")
        } catch let error as ExtractionError {
            guard case .notReadable(let reason, _, _) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(reason == "subscribe to continue")
            #expect(error.mightNeedInteraction)
        }
    }

    @Test func wholePageModeReadsEvenWithoutAnArticle() async throws {
        let article = try await ArticleExtractor().extract(url: try fixture("paywall"), mode: .wholePage)
        #expect(article.blocks.contains { $0.plainText.contains("phone call") })
    }

    @Test func rejectsNonWebSchemes() async {
        await #expect(throws: ExtractionError.invalidURL) {
            _ = try await ArticleExtractor().extract(url: URL(string: "mailto:someone@example.com")!)
        }
    }

    @Test func buildsDocumentFromExtractedArticle() async throws {
        let article = try await ArticleExtractor().extract(url: try fixture("article"))
        let doc = DocumentBuilder.build(article)
        #expect(doc.sentences.first.map { doc.string(for: $0.range) } == "The River Rises")
        #expect(doc.sentences.count > 12)
        // The code block is displayed but never inside a sentence.
        let code = try #require(doc.blocks.first { $0.kind == .code })
        #expect(code.sentenceIndices.isEmpty)
    }
}

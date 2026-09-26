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

    @Test func encyclopediaFurnitureAndApparatusAreDropped() async throws {
        let article = try await ArticleExtractor().extract(url: try fixture("encyclopedia"))
        let text = article.blocks.map(\.plainText).joined(separator: "\n")
        #expect(text.contains("Hummingbirds are birds native to the Americas"))
        #expect(text.contains("eighty times per second"))
        #expect(text.contains("Bee hummingbird"))            // data tables stay
        #expect(!text.contains("Temporal range"))            // infobox
        #expect(!text.contains("Animalia"))
        #expect(!text.contains("For other uses"))            // hatnote
        #expect(!text.contains("[edit]"))
        #expect(!text.contains("[1]"))
        #expect(!text.contains("navigation box"))
        #expect(!text.contains("List of hummingbirds"))      // See also
        #expect(!text.contains("361 species"))               // citation-list Notes
        #expect(!text.contains("Example Press"))             // References
        #expect(!text.contains("Hummingbird videos"))        // External links
        #expect(article.siteName == nil)                     // corporate publisher name is not a site name
        #expect(article.displayHost == nil || article.displayHost?.contains("Inc") == false)
    }

    @Test func proseNotesSectionIsKept() async throws {
        let html = """
        <html lang="en"><head><title>An Essay</title></head><body><article><h1>An Essay</h1>
        <p>\(String(repeating: "Great work comes from curiosity, delight and the desire to do something impressive. ", count: 6))</p>
        <h2>Notes</h2>
        <p>[1] I mean this in the sense of a problem that takes years, not an afternoon, to understand properly.</p>
        </article></body></html>
        """
        let article = try await ArticleExtractor().extract(html: html, baseURL: URL(string: "https://example.com/essay")!)
        #expect(article.blocks.contains { $0.plainText.contains("takes years") })
    }

    @Test func collapsedMobileSectionsAreReadAndSiteSuffixIsDropped() async throws {
        let para = String(repeating: "Hummingbirds hover by rotating their wings in a figure-eight pattern at great speed. ", count: 5)
        let html = """
        <html lang="en"><head><title>Hummingbird - Wikipedia</title><meta name="author" content="Contributors to Wikimedia projects"></head><body><main><div id="content">
        <h1>Hummingbird</h1>
        <section><p>\(para)</p></section>
        <h2>Description</h2>
        <section hidden="until-found"><p>Collapsed section text about plumage. \(para)</p></section>
        <h2>Migration</h2>
        <section hidden="until-found"><p>Some species migrate long distances every year. \(para)</p></section>
        <div hidden><p>Truly hidden furniture that should never be spoken aloud.</p></div>
        </div></main></body></html>
        """
        let article = try await ArticleExtractor().extract(html: html, baseURL: URL(string: "https://en.wikipedia.org/wiki/Hummingbird")!)
        let text = article.blocks.map(\.plainText).joined(separator: "\n")
        #expect(article.title == "Hummingbird")
        #expect(article.byline == nil)
        #expect(text.contains("Collapsed section text about plumage"))
        #expect(text.contains("migrate long distances"))
        #expect(!text.contains("Truly hidden furniture"))
    }

    @Test func fontWrappedFootnoteMarkersStayInTheirParagraph() async throws {
        let prose = String(repeating: "Great work tends to come from people who are curious about a field. ", count: 5)
        let html = """
        <html><head><title>How to Do Great Work</title></head><body><table><tr><td><font size=2 face="verdana">
        \(prose)<a href="#f1n"><font color=#dddddd>[<font color=#999999>1</font>]</font></a><br /><br />
        <b>Notes</b><br /><br />[<a name="f1n"><font color=#000000>1</font></a>]
        That second qualifier is critical, and it is worth saying again at some length here.<br /><br />
        [<a name="f2n"><font color=#000000>2</font></a>]
        Another note that follows the first one and also has enough words to be a paragraph.
        </font></td></tr></table></body></html>
        """
        let article = try await ArticleExtractor().extract(html: html, baseURL: URL(string: "https://paulgraham.com/greatwork.html")!)
        let texts = article.blocks.map { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(!texts.contains("["))
        #expect(texts.contains { $0.hasPrefix("[1]") && $0.contains("That second qualifier") })
        #expect(texts.contains { $0.hasPrefix("[2]") && $0.contains("Another note") })
    }

    @Test func titleKeepsColonsAndUnrelatedSegments() async throws {
        let body = String(repeating: "A long paragraph about processors and their design trade-offs in practice. ", count: 6)
        for (title, expected) in [("Apple: The New Chips", "Apple: The New Chips"),
                                  ("Rust vs. Go - A Comparison", "Rust vs. Go - A Comparison"),
                                  ("The Verge | Chips Explained", "Chips Explained")] {
            let html = "<html><head><title>\(title)</title><meta property=\"og:site_name\" content=\"The Verge\"></head>"
                + "<body><article><p>\(body)</p></article></body></html>"
            let article = try await ArticleExtractor().extract(html: html, baseURL: URL(string: "https://www.example.com/a")!)
            #expect(article.title == expected)
        }
    }

    @Test func meteredTeaserIsMarkedAsPreview() async throws {
        let article = try await ArticleExtractor().extract(url: try fixture("metered"))
        #expect(article.isPreview == true)
        #expect(article.blocks.contains { $0.plainText.contains("sticky services prices") })
        let full = try await ArticleExtractor().extract(url: try fixture("article"))
        #expect(full.isPreview == nil)
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

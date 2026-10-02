import Foundation
import Testing
@testable import ReadAloudKit

@MainActor
@Suite(.serialized)
struct ExtractionFidelityTests {
    func extract(_ body: String, mode: ExtractionMode = .wholePage) async throws -> Article {
        try await ArticleExtractor().extract(html: "<html lang='en'><head><title>Field guide</title></head><body>\(body)</body></html>",
                                             baseURL: URL(string: "https://example.com/guide/"), mode: mode)
    }

    @Test func lazyImagesUseTheRealSourceInsteadOfPlaceholders() async throws {
        let article = try await extract("""
        <p>A guide to photographs.</p>
        <img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="river.jpg" alt="River">
        <img src="placeholder.gif" data-lazy-src="mountain.jpg" alt="Mountain">
        <picture><source srcset="forest-small.jpg 400w, forest.jpg 1200w, forest-huge.jpg 2400w"><img alt="Forest"></picture>
        """)
        let paths = article.blocks.compactMap { b -> String? in
            if case .image(let url, _) = b.kind { return url?.lastPathComponent }; return nil
        }
        #expect(paths == ["river.jpg", "mountain.jpg", "forest.jpg"])
    }

    @Test func orderedListsPreserveZeroExplicitValuesAndReversedCounting() async throws {
        let article = try await extract("""
        <ol start="0"><li>Zero</li><li value="5">Five</li><li>Six</li></ol>
        <ol reversed><li>Three</li><li>Two</li><li>One</li></ol>
        <ol reversed start="8"><li>Eight</li><li value="3">Three again</li><li>Two again</li></ol>
        """)
        let numbers = article.blocks.compactMap { b -> Int? in
            if case .listItem(true, let number, _) = b.kind { return number }; return nil
        }
        #expect(numbers == [0, 5, 6, 3, 2, 1, 8, 3, 2])
    }

    @Test func hiddenListAndTableContentNeverLeaksIntoNarration() async throws {
        let article = try await extract("""
        <ul><li hidden>Hidden item</li><li><p>Visible item</p><p style="display:none">Hidden paragraph</p></li></ul>
        <table><caption>Measurements</caption><tr><th>Species</th><th>Length</th></tr>
        <tr><td>Finch<span hidden>Hidden label</span></td><td>Four inches</td></tr>
        <tr hidden><td>Hidden row</td><td>Secret</td></tr></table>
        """)
        let text = article.blocks.map(\.plainText).joined(separator: "\n")
        #expect(!text.contains("Hidden"))
        #expect(!text.contains("Secret"))
        #expect(text.contains("Visible item"))
        #expect(text.contains("Measurements"))
        #expect(text.contains("Finch · Four inches"))
    }

    @Test func inlineFormattingRemainsInsideNestedLists() async throws {
        let article = try await extract("""
        <ol><li><p>First <strong>important</strong> step.</p><ul><li>A nested step.</li></ul><p>Continue here.</p></li>
        <li><p>The next step.</p></li></ol>
        """)
        let items = article.blocks.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 4)
        #expect(items[0].runs.contains { $0.bold && $0.text == "important" })
        #expect(items[1].kind == .listItem(ordered: false, number: 1, depth: 1))
        #expect(items[2].kind == .listItem(ordered: true, number: 1, depth: 0))
        #expect(items[3].kind == .listItem(ordered: true, number: 2, depth: 0))
    }
    @Test func unspacedLanguagesRemainReadableArticles() async throws {
        for (language, passage) in [
            ("zh-Hans", "蜂鸟是一种生活在美洲的小型鸟类，它们能够在空中悬停，也能够向后飞行。科学家通过观察翅膀的运动来研究它们独特的飞行方式。保护森林和花卉有助于这些鸟类在自然环境中生存。"),
            ("ja", "ハチドリはアメリカ大陸に生息する小さな鳥です。空中で止まることができ、花の蜜を飲みながら植物の受粉を助けています。研究者たちは高速カメラで翼の動きを観察し、その飛行の仕組みを調べています。")
        ] {
            let body = (0..<4).map { _ in "<p>\(passage)</p>" }.joined()
            let html = "<html lang='\(language)'><head><title>鳥の観察</title></head><body><article>\(body)</article></body></html>"
            let article = try await ArticleExtractor().extract(html: html, baseURL: URL(string: "https://example.com/birds"))
            #expect(article.language == language)
            #expect(article.wordCount > 50)
            #expect(DocumentBuilder.build(article).words.count > 50)
        }
    }

}

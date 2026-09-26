import Foundation
import Testing
@testable import ReadAloudKit

/// Real-network extraction timings. Opt in with READALOUD_NETWORK_TESTS=1 (kept out of the default run so
/// the suite stays hermetic).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["READALOUD_NETWORK_TESTS"] == "1"))
struct LiveExtractionTests {
    static let pages = [
        "https://en.wikipedia.org/wiki/Hummingbird",
        "https://paulgraham.com/greatwork.html",
        "https://www.theverge.com/tech",
        "https://arstechnica.com/science/",
    ]

    @Test(arguments: pages) func extractsRealPagesPromptly(_ page: String) async throws {
        let start = Date()
        let article = try await ArticleExtractor().extract(url: URL(string: page)!, mode: .wholePage)
        let elapsed = Date().timeIntervalSince(start)
        let words = article.blocks.map(\.plainText).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        print(String(format: "LIVE %-45@ %5.1fs %6d words", page as NSString, elapsed, words))
        #expect(words > 200)
    }

    @Test func blockedImageLoadsStillYieldImageBlocks() async throws {
        let article = try await ArticleExtractor().extract(url: URL(string: "https://en.wikipedia.org/wiki/Hummingbird")!)
        let images = article.blocks.filter { if case .image = $0.kind { return true }; return false }
        print("LIVE images in Hummingbird article:", images.count)
        #expect(images.count >= 3)
    }
}

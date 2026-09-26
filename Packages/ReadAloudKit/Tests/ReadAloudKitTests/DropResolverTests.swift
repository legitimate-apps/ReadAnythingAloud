import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ReadAloudKit

@MainActor
struct DropResolverTests {
    private func provider(_ items: [(UTType, Result<Data, Error>)]) -> NSItemProvider {
        let provider = NSItemProvider()
        for (type, result) in items {
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                switch result {
                case .success(let data): completion(data, nil)
                case .failure(let error): completion(nil, error)
                }
                return nil
            }
        }
        return provider
    }

    private func utf8(_ s: String) -> Result<Data, Error> { .success(Data(s.utf8)) }

    @Test func browserLinkDragResolvesToTheLinkNotItsTitle() async {
        // A link dragged out of Safari: the URL plus the link's text as plain text.
        let drop = provider([(.url, utf8("https://www.reddit.com/r/test/comments/abc/post/")),
                             (.utf8PlainText, utf8("I know, but seeing if you do… Go"))])
        #expect(await DropResolver.resolve([drop]) == .webURL(URL(string: "https://www.reddit.com/r/test/comments/abc/post/")!))
    }

    @Test func failingURLRepresentationFallsBackToALinkInTheText() async {
        struct Broken: Error {}
        let drop = provider([(.url, .failure(Broken())),
                             (.utf8PlainText, utf8("https://example.com/story?id=7"))])
        #expect(await DropResolver.resolve([drop]) == .webURL(URL(string: "https://example.com/story?id=7")!))
    }

    @Test func htmlOnlyDragUsesTheFirstLink() async {
        let drop = provider([(.html, utf8(#"<a href="https://example.com/a?x=1&amp;y=2">A story</a>"#))])
        #expect(await DropResolver.resolve([drop]) == .webURL(URL(string: "https://example.com/a?x=1&y=2")!))
    }

    @Test func linkInsideSharedTextIsFound() async {
        let drop = provider([(.utf8PlainText, utf8("Look at this https://example.com/read later"))])
        #expect(await DropResolver.resolve([drop]) == .webURL(URL(string: "https://example.com/read")!))
    }

    @Test func plainArticleTextStaysText() async {
        let text = "Kingfishers are a family of small to medium-sized, brightly coloured birds."
        let drop = provider([(.utf8PlainText, utf8(text))])
        #expect(await DropResolver.resolve([drop]) == .text(text))
    }

    @Test func fileDropResolvesToTheFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID()).webloc")
        try Data().write(to: file)
        let drop = provider([(.fileURL, .success(file.dataRepresentation))])
        #expect(await DropResolver.resolve([drop]) == .fileURL(file))
    }

    @Test func emptyDropResolvesToNothing() async {
        #expect(await DropResolver.resolve([NSItemProvider()]) == nil)
    }
}

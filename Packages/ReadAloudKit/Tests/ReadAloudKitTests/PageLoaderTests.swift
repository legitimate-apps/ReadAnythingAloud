import Foundation
import Network
import Testing
import WebKit
@testable import ReadAloudKit

/// Actual WebKit navigations, served entirely on loopback with no internet dependency.
@MainActor
@Suite(.serialized)
struct PageLoaderTests {
    @Test func loadsHTMLFromLoopback() async throws {
        let server = try await ExtractionHTTPServer.start { _ in .init(body: "<html><body>Ready</body></html>") }
        defer { server.stop() }
        let webView = ArticleExtractor.makeWebView()
        try await PageLoader(webView: webView).load(server.url, timeout: 5)
        #expect(try await webView.evaluateJavaScript("document.body.innerText") as? String == "Ready")
    }

    @Test func followsClientSideRedirectToArticle() async throws {
        let server = try await ExtractionHTTPServer.start { path in
            if path == "/" {
                return .init(body: "<html><script>location.replace('/article')</script></html>")
            }
            return .init(body: "<html><title>Destination</title><body><p>Redirected article.</p></body></html>")
        }
        defer { server.stop() }
        let article = try await ArticleExtractor().extract(url: server.url, mode: .wholePage, timeout: 5)
        #expect(article.sourceURL?.path == "/article")
        #expect(article.blocks.contains { $0.plainText == "Redirected article." })
    }

    @Test func cancellationDuringDOMSettlingDoesNotReturnAnArticle() async throws {
        let server = try await ExtractionHTTPServer.start { _ in
            .init(body: "<html><body><p>A short story.</p></body></html>")
        }
        defer { server.stop() }
        let host = PlatformView()
        let extractor = ArticleExtractor()
        extractor.hostView = { host }
        let task = Task { try await extractor.extract(url: server.url, mode: .wholePage) }
        defer { task.cancel() }
        try await server.waitForRequest()
        let webView = try #require(host.subviews.compactMap { $0 as? WKWebView }.first)
        var loaded = false
        for _ in 0..<200 {
            if (try? await webView.evaluateJavaScript("document.readyState === 'complete' && document.body.innerText === 'A short story.'")) as? Bool == true {
                loaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(loaded)
        // Let the navigation continuation enter the settling delay before canceling.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(arguments: ["application/pdf", "audio/mpeg", "video/mp4", "application/octet-stream"])
    func HTTPErrorTakesPrecedenceOverContentType(_ mime: String) async throws {
        let server = try await ExtractionHTTPServer.start { _ in
            .init(status: 403, mime: mime, body: "Forbidden")
        }
        defer { server.stop() }
        let loader = PageLoader(webView: ArticleExtractor.makeWebView())
        await #expect(throws: ExtractionError.httpStatus(403)) {
            try await loader.load(server.url, timeout: 3)
        }
    }

    @Test(arguments: ["application/pdf", "audio/mpeg", "video/mp4", "image/png", "application/octet-stream"])
    func unsupportedResponseFinishesWithoutWaitingForItsBody(_ mime: String) async throws {
        // WebKit may sniff image bytes before delivering response policy. Send a valid image
        // prefix, padded beyond its sniffing buffer, while leaving the HTTP body unfinished.
        var prefix = Data()
        if mime == "image/png" {
            prefix = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6foAAAAASUVORK5CYII=")!
            prefix.append(Data(repeating: 0, count: 2_048))
        }
        let server = try await ExtractionHTTPServer.start { _ in
            .init(mime: mime, body: "unused", bodyPrefix: prefix, withholdBody: true)
        }
        defer { server.stop() }
        let loader = PageLoader(webView: ArticleExtractor.makeWebView())
        await #expect(throws: ExtractionError.notHTML(mime)) {
            try await loader.load(server.url, timeout: 3)
        }
    }

    @Test func cancelledLoadThrowsCancellationAndCanBeReused() async throws {
        let server = try await ExtractionHTTPServer.start { path in
            path == "/stall" ? .init(withholdResponse: true) : .init(body: "<html><body>Ready</body></html>")
        }
        defer { server.stop() }
        let webView = ArticleExtractor.makeWebView()
        let loader = PageLoader(webView: webView)
        let task = Task { try await loader.load(server.url.appendingPathComponent("stall"), timeout: 5) }
        try await server.waitForRequest()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await loader.load(server.url, timeout: 3)
        #expect(try await webView.evaluateJavaScript("document.body.innerText") as? String == "Ready")
    }

    @Test func alreadyCancelledTaskDoesNotStartNavigation() async throws {
        let server = try await ExtractionHTTPServer.start { _ in .init(body: "<p>Should not load</p>") }
        defer { server.stop() }
        let loader = PageLoader(webView: ArticleExtractor.makeWebView())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await loader.load(server.url, timeout: 3)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func timeoutStopsTheLoadAndCanBeReused() async throws {
        let server = try await ExtractionHTTPServer.start { path in
            path == "/stall" ? .init(withholdResponse: true) : .init(body: "<p>Recovered</p>")
        }
        defer { server.stop() }
        let loader = PageLoader(webView: ArticleExtractor.makeWebView())
        await #expect(throws: ExtractionError.timedOut) {
            try await loader.load(server.url.appendingPathComponent("stall"), timeout: 0.25)
        }
        try await loader.load(server.url, timeout: 3)
    }

    @Test func reusedLoaderResetsEarlyReadinessForHTML() async throws {
        let server = try await ExtractionHTTPServer.start { path in
            path == "/stall" ? .init(withholdResponse: true) : .init(body: "<p>Ready</p>")
        }
        defer { server.stop() }
        let loader = PageLoader(webView: ArticleExtractor.makeWebView())
        try await loader.load(server.url, timeout: 3, finishWhenReadable: true)
        let html = "<html><body><p>" + String(repeating: "Readable text. ", count: 100)
            + "</p><img src='/stall'></body></html>"
        // This document becomes readable, but its image never finishes. loadHTML must wait for
        // navigation completion instead of inheriting the previous load's early-readiness mode.
        await #expect(throws: ExtractionError.timedOut) {
            try await loader.loadHTML(html, baseURL: server.url, timeout: 1.5)
        }
        #expect(server.requests.contains("/stall"))
    }

    @Test func reusedLoaderDoesNotKeepPreviousHTTPFailure() async throws {
        let server = try await ExtractionHTTPServer.start { _ in .init(status: 403, body: "<p>Forbidden</p>") }
        defer { server.stop() }
        let webView = ArticleExtractor.makeWebView()
        let loader = PageLoader(webView: webView)
        await #expect(throws: ExtractionError.httpStatus(403)) { try await loader.load(server.url, timeout: 3) }
        try await loader.loadHTML("<html><body>Local article</body></html>", baseURL: nil, timeout: 3)
        #expect(try await webView.evaluateJavaScript("document.body.innerText") as? String == "Local article")
    }
}

/// Small HTTP fixture server for navigation policy, stalled resources and client-rendered pages.
/// Owned by one test; callbacks enter the main actor and teardown closes every connection.
@MainActor
final class ExtractionHTTPServer {
    struct Response: Sendable {
        var status = 200
        var mime = "text/html; charset=utf-8"
        var body = ""
        var bodyPrefix = Data()
        var withholdBody = false
        var withholdResponse = false
    }

    private let listener: NWListener
    private let response: (String) -> Response
    private var connections: [NWConnection] = []
    private(set) var requests: [String] = []
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    private init(listener: NWListener, response: @escaping (String) -> Response) {
        self.listener = listener
        self.response = response
    }

    static func start(response: @escaping (String) -> Response) async throws -> ExtractionHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = ExtractionHTTPServer(listener: listener, response: response)
        listener.newConnectionHandler = { [weak server] connection in
            Task { @MainActor in server?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        return server
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    func waitForRequest() async throws {
        for _ in 0..<300 {
            if !requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ExtractionError.timedOut
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, accumulated: bytes) }
                    return
                }
                let path = String(request.split(separator: " ").dropFirst().first ?? "/")
                self.requests.append(path)
                let response = self.response(path)
                guard !response.withholdResponse else { return }
                let body = Data(response.body.utf8)
                let header = "HTTP/1.1 \(response.status) Fixture\r\nContent-Type: \(response.mime)\r\nContent-Length: \(body.count + response.bodyPrefix.count)\r\nConnection: close\r\n\r\n"
                var output = Data(header.utf8)
                output.append(response.bodyPrefix)
                if !response.withholdBody { output.append(body) }
                connection.send(content: output, completion: .contentProcessed { _ in
                    if !response.withholdBody { connection.cancel() }
                })
            }
        }
    }
}

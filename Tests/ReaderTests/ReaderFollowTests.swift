import AppKit
import ReadAloudKit
import XCTest

@MainActor
final class ReaderFollowTests: XCTestCase {
    func testRejoiningPausedSentenceRevealsItImmediately() async throws {
        try await checkRejoin(duringScroll: false)
    }

    func testRejoiningDuringLiveScrollRevealsWhenScrollingEnds() async throws {
        try await checkRejoin(duringScroll: true)
    }

    func testDeferredRejoinAfterPlaybackAdvancesToDistantSentence() async throws {
        try await checkRejoin(duringScroll: true, advanceTarget: true)
    }

    private func checkRejoin(duringScroll: Bool, advanceTarget: Bool = false) async throws {
        _ = NSApplication.shared
        let document = DocumentBuilder.build(Article(title: "Reader follow check", language: "en", blocks:
            (0..<70).map { Block(kind: .paragraph, text: "Paragraph \($0) keeps the reader focused on the spoken sentence while allowing a quiet look ahead.") }))
        var sentence = document.sentences[30].range
        var configuration = ReaderTextConfiguration(sentenceRange: sentence, wordRange: nil,
                                                    follow: true, jumpCounter: 0, bottomInset: 90)
        let style = ReaderStyle(theme: .paper)
        let parent = ReaderTextView(document: document, style: style, configuration: configuration,
                                    onTapWord: { _ in }, onUserScroll: {})
        let coordinator = parent.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        let textView = ReaderNSTextView(usingTextLayoutManager: true)
        textView.frame = scroll.bounds
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = style.background
        scroll.documentView = textView
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }
        coordinator.parent = parent
        coordinator.scrollView = scroll
        coordinator.textView = textView
        coordinator.rebuildIfNeeded(document: document, style: style)
        coordinator.apply(configuration, animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let readingOrigin = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(readingOrigin, 600, "The target must start well beyond the first viewport")

        if duringScroll { coordinator.willStartLiveScroll() }
        configuration.follow = false
        coordinator.apply(configuration, animated: false)
        scroll.contentView.setBoundsOrigin(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.apply(configuration, animated: false)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1, "Browsing must not snap back")
        attach(scroll, name: "Browsing away from paused sentence")

        if advanceTarget {
            sentence = document.sentences[60].range
            configuration.sentenceRange = sentence
            coordinator.apply(configuration, animated: false)
        }
        configuration.follow = true
        coordinator.apply(configuration, animated: false)
        if duringScroll {
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1,
                           "An active scroll gesture must not be fought")
            coordinator.didEndLiveScroll()
        }
        try await Task.sleep(for: .milliseconds(500))
        let layout = try XCTUnwrap(textView.textLayoutManager)
        let rect = try XCTUnwrap(HighlightGeometry.rects(for: sentence.ns, in: layout, fontSize: style.fontSize).first)
        let sentenceTop = rect.minY + textView.textContainerOrigin.y
        let viewport = scroll.documentVisibleRect
        let usableHeight = viewport.height - configuration.bottomInset
        XCTAssertGreaterThan(sentenceTop, viewport.minY + usableHeight * 0.1)
        XCTAssertLessThan(sentenceTop, viewport.minY + usableHeight * 0.72,
                          "Back to reading must reveal the same sentence without requiring playback to advance")
        attach(scroll, name: "Rejoined paused sentence")
    }

    private func attach(_ view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else { return }
        if let directory = ProcessInfo.processInfo.environment["READALOUD_READER_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".jpg")
            try? jpeg.write(to: url)
        }
        let attachment = XCTAttachment(data: jpeg, uniformTypeIdentifier: "public.jpeg")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

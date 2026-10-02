import ReadAloudKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Everything the text view needs to render one frame of the reader.
struct ReaderTextConfiguration: Equatable {
    var sentenceRange: TextSpan?
    var wordRange: TextSpan?
    var follow: Bool
    /// Changes whenever the playhead jumps, forcing a scroll even when follow is off.
    var jumpCounter: Int
    var bottomInset: CGFloat
}

// MARK: - Shared geometry

@MainActor
enum HighlightGeometry {
    /// Lays out everything from the top of the document through `offset`. TextKit 2 only lays out around the
    /// viewport and estimates the rest, so a far-away target (a resumed position, a long seek) must be laid out
    /// together with the text above it before its position and the document height are exact.
    static func ensureLayout(through offset: Int, in tlm: NSTextLayoutManager) {
        guard let tcm = tlm.textContentManager else { return }
        let docStart = tcm.documentRange.location
        let end = tcm.location(docStart, offsetBy: offset) ?? tcm.documentRange.endLocation
        if let range = NSTextRange(location: docStart, end: end) { tlm.ensureLayout(for: range) }
    }

    /// Line-fragment rects covering `range`, in text-container coordinates, trimmed to the glyph height so the
    /// highlight hugs the text instead of filling the line's extra leading.
    static func rects(for range: NSRange, in tlm: NSTextLayoutManager, fontSize: CGFloat) -> [CGRect] {
        guard range.length > 0, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        tlm.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, baseline, _ in
            guard frame.width > 0.5 else { return true }
            // Glyph box: ascender above the baseline, descender below, whatever the line spacing.
            let ascent = fontSize * 0.98
            let descent = fontSize * 0.30
            let top = frame.minY + baseline - ascent
            let height = ascent + descent
            let r = CGRect(x: frame.minX, y: max(frame.minY, top), width: frame.width, height: min(frame.height, height))
            rects.append(r)
            return true
        }
        return merge(rects)
    }

    /// Joins segments on the same line.
    static func merge(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects {
            if let last = out.last, abs(last.midY - r.midY) < 2 {
                out[out.count - 1] = last.union(r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func sentencePath(_ rects: [CGRect], padX: CGFloat, padY: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for r in rects {
            let box = r.insetBy(dx: -padX, dy: -padY)
            path.addRoundedRect(in: box, cornerWidth: min(radius, box.height / 2), cornerHeight: min(radius, box.height / 2))
        }
        return path
    }
}

#if os(iOS)

// MARK: - iOS

struct ReaderTextView: UIViewRepresentable {
    let document: ReadingDocument
    let style: ReaderStyle
    let configuration: ReaderTextConfiguration
    var onTapWord: (Int) -> Void
    var onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ReaderUITextView {
        let view = ReaderUITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.adjustsFontForContentSizeCategory = false
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "reader.text"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: ReaderUITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        view.backgroundColor = style.background
        view.indicatorStyle = style.effectiveDark ? .white : .black
        c.rebuildIfNeeded(document: document, style: style)
        c.apply(configuration, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView?
        weak var textView: ReaderUITextView?
        private var builtFor: (id: UUID, style: ReaderStyle, width: CGFloat)?
        private var lastConfig: ReaderTextConfiguration?
        private var lastScrolledSentence: TextSpan?
        private var userIsScrolling = false
        /// Set when new text is installed: the next reveal lays out through its target first.
        private var needsFullLayout = true

        func rebuildIfNeeded(document: ReadingDocument, style: ReaderStyle) {
            guard let view = textView else { return }
            let width = view.bounds.width
            guard width > 0 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let p = self.parent else { return }
                    self.rebuildIfNeeded(document: p.document, style: p.style)
                    self.apply(p.configuration, animated: false)
                }
                return
            }
            if let built = builtFor, built.id == document.articleID, built.style == style, abs(built.width - width) < 1 { return }
            let firstBuild = builtFor?.id != document.articleID
            let anchor = firstBuild ? nil : topVisibleOffset()
            let horizontal = max(20, (width - style.maxLineWidth) / 2)
            view.textContainerInset = UIEdgeInsets(top: 24, left: horizontal, bottom: 140, right: horizontal)
            let text = ArticleTextBuilder.build(document, style: style, containerWidth: width - horizontal * 2)
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                (value as? ImageAttachment)?.onLoad = { [weak self] in self?.relayout() }
            }
            view.attributedText = text
            view.highlight.style = style
            builtFor = (document.articleID, style, width)
            lastScrolledSentence = nil
            needsFullLayout = true
            if let anchor { scroll(toOffset: anchor, animated: false) }
            view.highlight.invalidate()
        }

        private func relayout() {
            guard let view = textView, let tlm = view.textLayoutManager else { return }
            tlm.invalidateLayout(for: tlm.documentRange)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            view.highlight.invalidate()
            if let p = parent { apply(p.configuration, animated: false) }
        }

        func apply(_ config: ReaderTextConfiguration, animated: Bool) {
            guard let view = textView, builtFor != nil else { return }
            let jumped = config.jumpCounter != lastConfig?.jumpCounter
            let rejoined = config.follow && lastConfig?.follow == false
            // A rejoin can arrive while a drag/deceleration is finishing. Keep the reveal pending.
            if rejoined { lastScrolledSentence = nil }
            view.contentInset.bottom = config.bottomInset
            view.verticalScrollIndicatorInsets.bottom = config.bottomInset
            let refreshGeometry = jumped || rejoined || needsFullLayout
            if let sentence = config.sentenceRange, (config.follow || jumped), !userIsScrolling,
               sentence != lastScrolledSentence || jumped || rejoined {
                lastScrolledSentence = sentence
                reveal(sentence, animated: animated, force: jumped || rejoined)
            }
            if refreshGeometry { view.highlight.invalidate() }
            view.highlight.update(sentence: parent?.style.highlight.showsSentence == true ? config.sentenceRange : nil,
                                  word: parent?.style.highlight.showsWord == true ? config.wordRange : nil,
                                  in: view, animated: animated && !jumped)
            lastConfig = config
        }

        /// Scrolls so the sentence sits in the upper-middle of the viewport, unless it's already comfortably visible.
        private func reveal(_ range: TextSpan, animated: Bool, force: Bool) {
            guard let view = textView, let tlm = view.textLayoutManager else { return }
            if force || needsFullLayout {
                HighlightGeometry.ensureLayout(through: range.upperBound, in: tlm)
                view.layoutIfNeeded()
                needsFullLayout = false
            }
            let rects = HighlightGeometry.rects(for: range.ns, in: tlm, fontSize: parent?.style.fontSize ?? 18)
            guard let first = rects.first, let last = rects.last else { return }
            let top = first.minY + view.textContainerInset.top
            let bottom = last.maxY + view.textContainerInset.top
            let visible = view.bounds.inset(by: view.adjustedContentInset)
            let band = visible.minY + visible.height * 0.12 ... visible.minY + visible.height * 0.72
            if !force, band.contains(top), bottom < visible.maxY - 20 { return }
            let targetY = top - visible.height * 0.28
            let maxY = max(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            let y = min(max(targetY, -view.adjustedContentInset.top), maxY)
            view.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }

        private func topVisibleOffset() -> Int? {
            guard let view = textView,
                  let position = view.closestPosition(to: CGPoint(x: view.bounds.midX, y: view.contentOffset.y + view.adjustedContentInset.top + 30))
            else { return nil }
            return view.offset(from: view.beginningOfDocument, to: position)
        }

        private func scroll(toOffset offset: Int, animated: Bool) {
            guard let view = textView, let tlm = view.textLayoutManager else { return }
            let rects = HighlightGeometry.rects(for: NSRange(location: offset, length: 1), in: tlm, fontSize: 18)
            guard let r = rects.first else { return }
            view.setContentOffset(CGPoint(x: 0, y: max(0, r.minY + view.textContainerInset.top - 30)), animated: animated)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, let parent, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            // Ignore taps in the margins or far below the text.
            if let tlm = view.textLayoutManager {
                let rects = HighlightGeometry.rects(for: NSRange(location: max(0, offset - 1), length: 1), in: tlm, fontSize: parent.style.fontSize)
                if let r = rects.first?.offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top),
                   abs(r.midY - point.y) > parent.style.fontSize * 2.5 { return }
            }
            if let word = parent.document.wordIndex(atOffset: offset) {
                UISelectionFeedbackGenerator().selectionChanged()
                parent.onTapWord(word)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userIsScrolling = true
            parent?.onUserScroll()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll()
        }

        private func finishUserScroll() {
            userIsScrolling = false
            if let config = lastConfig { apply(config, animated: true) }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {}
    }
}

/// UITextView with a highlight layer inserted behind the text.
final class ReaderUITextView: UITextView {
    let highlight = HighlightOverlay()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        insertSubview(highlight, at: 0)
    }

    convenience init(usingTextLayoutManager: Bool) {
        self.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: max(contentSize.height, bounds.height)))
        if subviews.first !== highlight { sendSubviewToBack(highlight) }
    }
}

/// Draws the sentence tint and the word pill with Core Animation layers.
final class HighlightOverlay: UIView {
    var style = ReaderStyle()
    private let sentenceLayer = CAShapeLayer()
    private let wordLayer = CALayer()
    private var sentence: TextSpan?
    private var word: TextSpan?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(sentenceLayer)
        layer.addSublayer(wordLayer)
        wordLayer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func invalidate() {
        sentence = nil
        word = nil
    }

    func update(sentence newSentence: TextSpan?, word newWord: TextSpan?, in view: UITextView, animated: Bool) {
        guard let tlm = view.textLayoutManager else { return }
        let origin = CGPoint(x: view.textContainerInset.left, y: view.textContainerInset.top)
        let size = style.fontSize

        if newSentence != sentence {
            sentence = newSentence
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sentenceLayer.fillColor = style.sentenceFill.cgColor
            if let s = newSentence {
                let rects = HighlightGeometry.rects(for: s.ns, in: tlm, fontSize: size).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                sentenceLayer.path = HighlightGeometry.sentencePath(rects, padX: size * 0.22, padY: size * 0.12, radius: size * 0.3)
            } else {
                sentenceLayer.path = nil
            }
            CATransaction.commit()
        }

        if newWord != word {
            word = newWord
            let rect = newWord.flatMap { HighlightGeometry.rects(for: $0.ns, in: tlm, fontSize: size).first }?
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -size * 0.16, dy: -size * 0.06)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            if !animated || wordLayer.opacity == 0 { CATransaction.setDisableActions(true) }
            wordLayer.backgroundColor = style.wordFill.cgColor
            wordLayer.cornerRadius = size * 0.28
            if let rect {
                // Don't animate across lines: that sweeps through the text.
                if abs(wordLayer.frame.midY - rect.midY) > 2 { CATransaction.setDisableActions(true) }
                wordLayer.frame = rect
                wordLayer.opacity = 1
            } else {
                wordLayer.opacity = 0
            }
            CATransaction.commit()
        }
    }
}

#else

// MARK: - macOS

struct ReaderTextView: NSViewRepresentable {
    let document: ReadingDocument
    let style: ReaderStyle
    let configuration: ReaderTextConfiguration
    var onTapWord: (Int) -> Void
    var onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder

        let textView = ReaderNSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("reader.text")
        textView.onClick = { [weak coordinator = context.coordinator] offset in coordinator?.clicked(offset) }
        scroll.documentView = textView

        context.coordinator.scrollView = scroll
        context.coordinator.textView = textView
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.willStartLiveScroll),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didEndLiveScroll),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsFrameChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        scroll.backgroundColor = style.background
        c.textView?.backgroundColor = style.background
        c.rebuildIfNeeded(document: document, style: style)
        c.apply(configuration, animated: true)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ReaderTextView?
        weak var scrollView: NSScrollView?
        weak var textView: ReaderNSTextView?
        private var builtFor: (id: UUID, style: ReaderStyle, width: CGFloat)?
        private var lastConfig: ReaderTextConfiguration?
        private var lastScrolledSentence: TextSpan?
        private var userIsScrolling = false
        /// Set when new text is installed: the next reveal lays out through its target first.
        private var needsFullLayout = true

        func rebuildIfNeeded(document: ReadingDocument, style: ReaderStyle) {
            guard let scroll = scrollView, let view = textView else { return }
            let width = scroll.contentSize.width
            guard width > 0 else { return }
            if let built = builtFor, built.id == document.articleID, built.style == style, abs(built.width - width) < 1 { return }
            let sameDocument = builtFor?.id == document.articleID
            let anchor = sameDocument ? topVisibleOffset() : nil
            let horizontal = max(28, (width - style.maxLineWidth) / 2)
            view.textContainerInset = NSSize(width: horizontal, height: 36)
            let text = ArticleTextBuilder.build(document, style: style, containerWidth: width - horizontal * 2)
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                (value as? ImageAttachment)?.onLoad = { [weak self] in self?.relayout() }
            }
            view.textStorage?.setAttributedString(text)
            view.highlightStyle = style
            view.selectedTextAttributes = [.backgroundColor: style.accent.withAlphaComponent(0.25)]
            builtFor = (document.articleID, style, width)
            lastScrolledSentence = nil
            needsFullLayout = true
            view.resetHighlight()
            if let anchor { scrollTo(offset: anchor) }
        }

        private func relayout() {
            guard let view = textView, let tlm = view.textLayoutManager else { return }
            tlm.invalidateLayout(for: tlm.documentRange)
            view.needsLayout = true
            view.resetHighlight()
            if let p = parent { apply(p.configuration, animated: false) }
        }

        func apply(_ config: ReaderTextConfiguration, animated: Bool) {
            guard let view = textView, builtFor != nil, let style = parent?.style else { return }
            let jumped = config.jumpCounter != lastConfig?.jumpCounter
            let rejoined = config.follow && lastConfig?.follow == false
            // A rejoin can arrive while a drag/deceleration is finishing. Keep the reveal pending.
            if rejoined { lastScrolledSentence = nil }
            scrollView?.contentInsets.bottom = config.bottomInset
            let refreshGeometry = jumped || rejoined || needsFullLayout
            if let sentence = config.sentenceRange, config.follow || jumped, !userIsScrolling,
               sentence != lastScrolledSentence || jumped || rejoined {
                lastScrolledSentence = sentence
                reveal(sentence, force: jumped || rejoined)
            }
            if refreshGeometry { view.resetHighlight() }
            view.setHighlight(sentence: style.highlight.showsSentence ? config.sentenceRange : nil,
                              word: style.highlight.showsWord ? config.wordRange : nil,
                              animated: animated && !jumped)
            lastConfig = config
        }

        private func reveal(_ range: TextSpan, force: Bool) {
            guard let scroll = scrollView, let view = textView, let tlm = view.textLayoutManager else { return }
            let initial = needsFullLayout
            if force || needsFullLayout {
                HighlightGeometry.ensureLayout(through: range.upperBound, in: tlm)
                // NSTextView only grows to what TextKit 2 has laid out so far; make room for the target now.
                let needed = tlm.usageBoundsForTextContainer.maxY + view.textContainerInset.height * 2
                if view.frame.height < needed { view.setFrameSize(NSSize(width: view.frame.width, height: needed)) }
                needsFullLayout = false
            }
            let rects = HighlightGeometry.rects(for: range.ns, in: tlm, fontSize: parent?.style.fontSize ?? 18)
            guard let first = rects.first, let last = rects.last else { return }
            let origin = view.textContainerOrigin
            let top = first.minY + origin.y
            let bottom = last.maxY + origin.y
            let visible = scroll.documentVisibleRect
            let usable = visible.height - (scroll.contentInsets.bottom)
            if !force, top > visible.minY + usable * 0.1, bottom < visible.minY + usable * 0.75 { return }
            let docHeight = view.frame.height
            let y = min(max(0, top - usable * 0.28), max(0, docHeight - visible.height + scroll.contentInsets.bottom))
            if initial {
                // Freshly installed text: jump straight there, and again after the window's first layout pass.
                // The (invisible, read-only) insertion point moves along too: AppKit scrolls a text view to its
                // selection when it becomes first responder, which would otherwise snap back to the top.
                view.setSelectedRange(NSRange(location: range.location, length: 0))
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.scrollView, !self.userIsScrolling else { return }
                    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func topVisibleOffset() -> Int? {
            guard let scroll = scrollView, let view = textView else { return nil }
            let point = NSPoint(x: view.bounds.midX, y: scroll.documentVisibleRect.minY + 40)
            let index = view.characterIndexForInsertion(at: point)
            return index == NSNotFound ? nil : index
        }

        private func scrollTo(offset: Int) {
            guard let scroll = scrollView, let view = textView, let tlm = view.textLayoutManager else { return }
            let rects = HighlightGeometry.rects(for: NSRange(location: offset, length: 1), in: tlm, fontSize: 18)
            guard let r = rects.first else { return }
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, r.minY + view.textContainerOrigin.y - 40)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func clicked(_ offset: Int) {
            guard let parent, let word = parent.document.wordIndex(atOffset: offset) else { return }
            parent.onTapWord(word)
        }

        @objc func willStartLiveScroll() {
            userIsScrolling = true
            parent?.onUserScroll()
        }

        @objc func didEndLiveScroll() {
            userIsScrolling = false
            if let config = lastConfig { apply(config, animated: true) }
        }

        @objc func frameChanged() {
            guard let p = parent else { return }
            rebuildIfNeeded(document: p.document, style: p.style)
            apply(p.configuration, animated: false)
        }
    }
}

/// NSTextView that paints the highlight in `drawBackground` (behind the glyphs) and animates the word pill.
final class ReaderNSTextView: NSTextView {
    var highlightStyle = ReaderStyle()
    var onClick: ((Int) -> Void)?

    private var sentenceRange: TextSpan?
    private var wordRange: TextSpan?
    private var sentenceRects: [CGRect] = []
    private var wordFrom: CGRect?
    private var wordTo: CGRect?
    private var animationStart: CFTimeInterval = 0
    private let animationDuration: CFTimeInterval = 0.14
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    func resetHighlight() {
        sentenceRange = nil
        wordRange = nil
        sentenceRects = []
        wordFrom = nil
        wordTo = nil
        needsDisplay = true
    }

    func setHighlight(sentence: TextSpan?, word: TextSpan?, animated: Bool) {
        guard let tlm = textLayoutManager else { return }
        let size = highlightStyle.fontSize
        let origin = textContainerOrigin
        if sentence != sentenceRange {
            let old = sentenceRects.reduce(CGRect.null) { $0.union($1) }
            sentenceRange = sentence
            sentenceRects = sentence.map {
                HighlightGeometry.rects(for: $0.ns, in: tlm, fontSize: size).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
            } ?? []
            let new = sentenceRects.reduce(CGRect.null) { $0.union($1) }
            setNeedsDisplay(old.union(new).insetBy(dx: -size, dy: -size))
        }
        if word != wordRange {
            wordRange = word
            let target = word.flatMap { HighlightGeometry.rects(for: $0.ns, in: tlm, fontSize: size).first }?
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -size * 0.16, dy: -size * 0.06)
            let current = currentWordRect()
            if animated, let current, let target, abs(current.midY - target.midY) < 2 {
                wordFrom = current
                wordTo = target
                animationStart = CACurrentMediaTime()
                startAnimation()
            } else {
                if let current { setNeedsDisplay(current.insetBy(dx: -4, dy: -4)) }
                wordFrom = nil
                wordTo = target
            }
            if let target { setNeedsDisplay(target.insetBy(dx: -4, dy: -4)) }
        }
    }

    private func progress() -> CGFloat {
        guard wordFrom != nil else { return 1 }
        let t = min(1, (CACurrentMediaTime() - animationStart) / animationDuration)
        return CGFloat(1 - pow(1 - t, 3)) // ease-out cubic
    }

    private func currentWordRect() -> CGRect? {
        guard let to = wordTo else { return nil }
        guard let from = wordFrom else { return to }
        let p = progress()
        return CGRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                      width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let from = self.wordFrom, let to = self.wordTo {
                    self.setNeedsDisplay(from.union(to).insetBy(dx: -4, dy: -4))
                }
                if self.progress() >= 1 {
                    self.wordFrom = nil
                    self.animationTimer?.invalidate()
                    self.animationTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let size = highlightStyle.fontSize
        if !sentenceRects.isEmpty {
            let path = HighlightGeometry.sentencePath(sentenceRects, padX: size * 0.22, padY: size * 0.12, radius: size * 0.3)
            highlightStyle.sentenceFill.setFill()
            let bezier = NSBezierPath(cgPath: path)
            bezier.fill()
        }
        if let word = currentWordRect() {
            highlightStyle.wordFill.setFill()
            NSBezierPath(roundedRect: word, xRadius: size * 0.28, yRadius: size * 0.28).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let clickCount = event.clickCount
        super.mouseDown(with: event) // runs the selection tracking loop until mouse-up
        guard clickCount == 1, selectedRange().length == 0 else { return }
        let end = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(end.x - start.x, end.y - start.y) < 5 else { return }
        let index = characterIndexForInsertion(at: start)
        guard index != NSNotFound else { return }
        onClick?(index)
    }
}

#endif

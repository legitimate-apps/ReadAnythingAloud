import ReadAloudKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Builds the styled attributed string for a `ReadingDocument`. Offsets match the document's UTF-16 ranges
/// exactly, so highlight and tap lookups can use document ranges directly.
@MainActor
enum ArticleTextBuilder {
    /// Attribute carrying the block index on each paragraph (used to find image attachments).
    static let imageURLKey = NSAttributedString.Key("ReadAloudImageURL")

    static func build(_ document: ReadingDocument, style: ReaderStyle, containerWidth: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(string: document.text)
        let full = NSRange(location: 0, length: out.length)
        let body = style.font(size: style.fontSize)
        out.addAttributes([.font: body, .foregroundColor: style.text, .paragraphStyle: paragraph(style, kind: .paragraph)], range: full)

        for block in document.blocks {
            let range = block.range.ns
            guard range.length > 0 || block.kind == .separator else { continue }
            // Include the trailing newline so paragraph attributes apply to the whole paragraph.
            let paraRange = NSRange(location: range.location, length: min(range.length + 1, out.length - range.location))
            out.addAttribute(.paragraphStyle, value: paragraph(style, kind: block.kind), range: paraRange)

            switch block.kind {
            case .heading(let level):
                let scale: CGFloat = [1.75, 1.40, 1.20, 1.08, 1.0, 1.0][min(max(level, 1), 6) - 1]
                let weight: PlatformFont.Weight = level == 1 ? .bold : .semibold
                out.addAttribute(.font, value: style.font(size: style.fontSize * scale, weight: weight), range: range)
            case .byline:
                out.addAttributes([.font: style.font(size: style.fontSize * 0.8), .foregroundColor: style.secondaryText], range: range)
            case .caption:
                out.addAttributes([.font: style.font(size: style.fontSize * 0.78, italic: false), .foregroundColor: style.secondaryText], range: range)
            case .quote:
                out.addAttributes([.font: style.font(size: style.fontSize * 1.02, italic: true)], range: range)
            case .code:
                out.addAttributes([.font: style.monospaced(size: style.fontSize * 0.78),
                                   .backgroundColor: style.codeBackground], range: range)
            case .listItem:
                let marker = NSRange(location: block.range.location, length: block.contentRange.location - block.range.location)
                out.addAttribute(.foregroundColor, value: style.secondaryText, range: marker)
            case .image(let url, let alt):
                let attachment = ImageAttachment(url: url, alt: alt, maxWidth: containerWidth, placeholderTint: style.codeBackground)
                out.addAttribute(.attachment, value: attachment, range: block.contentRange.ns)
            case .separator, .paragraph:
                break
            }

            for span in block.styles {
                let r = span.range.ns
                if span.code {
                    out.addAttributes([.font: style.monospaced(size: style.fontSize * 0.86), .backgroundColor: style.codeBackground], range: r)
                    continue
                }
                if span.bold || span.italic {
                    let current = (out.attribute(.font, at: r.location, effectiveRange: nil) as? PlatformFont) ?? body
                    let weight: PlatformFont.Weight = span.bold ? .bold : .regular
                    out.addAttribute(.font, value: style.font(size: current.pointSize, weight: weight, italic: span.italic || block.kind == .quote), range: r)
                }
                if span.link != nil {
                    // Taps move the playhead rather than follow links, so links are only hinted: body-colored text
                    // with a faint underline keeps link-dense pages (encyclopedias) calm to read along with.
                    out.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: style.link.withAlphaComponent(0.4)], range: r)
                }
            }
        }
        return out
    }

    static func paragraph(_ style: ReaderStyle, kind: Block.Kind) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = style.lineSpacing
        p.paragraphSpacing = style.fontSize * 0.85
        p.hyphenationFactor = 0.2
        switch kind {
        case .heading(let level):
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = style.fontSize * (level == 1 ? 0.2 : 1.1)
            p.paragraphSpacing = style.fontSize * (level == 1 ? 0.35 : 0.5)
            p.hyphenationFactor = 0
        case .byline:
            p.lineHeightMultiple = 1.2
            p.paragraphSpacing = style.fontSize * 1.6
        case .listItem(_, _, let depth):
            let indent = CGFloat(depth) * style.fontSize * 1.4
            let markerWidth = style.fontSize * 1.6
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            p.defaultTabInterval = style.fontSize * 1.4
            p.firstLineHeadIndent = indent
            p.headIndent = indent + markerWidth
            p.paragraphSpacing = style.fontSize * 0.4
        case .quote:
            p.firstLineHeadIndent = style.fontSize * 1.2
            p.headIndent = style.fontSize * 1.2
            p.tailIndent = -style.fontSize * 0.6
        case .code:
            p.lineHeightMultiple = 1.15
            p.hyphenationFactor = 0
            p.firstLineHeadIndent = style.fontSize * 0.6
            p.headIndent = style.fontSize * 0.6
        case .caption:
            p.alignment = .center
            p.lineHeightMultiple = 1.2
            p.paragraphSpacing = style.fontSize * 1.2
        case .image:
            p.alignment = .center
            p.lineHeightMultiple = 1
            p.paragraphSpacing = style.fontSize * 0.4
            p.paragraphSpacingBefore = style.fontSize * 0.4
        case .separator:
            p.paragraphSpacing = style.fontSize * 1.5
        case .paragraph:
            break
        }
        return p
    }
}

/// An image attachment that loads asynchronously and sizes itself to the text width.
@MainActor
final class ImageAttachment: NSTextAttachment {
    let url: URL?
    let alt: String?
    let maxWidth: CGFloat
    var aspect: CGFloat = 0.56
    var onLoad: (() -> Void)?

    init(url: URL?, alt: String?, maxWidth: CGFloat, placeholderTint: PlatformColor) {
        self.url = url
        self.alt = alt
        self.maxWidth = max(maxWidth, 100)
        super.init(data: nil, ofType: nil)
        image = Self.placeholder(tint: placeholderTint)
        bounds = CGRect(x: 0, y: 0, width: self.maxWidth, height: self.maxWidth * aspect)
        if let url { load(url) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func load(_ url: URL) {
        if let cached = ImageLoader.shared.cached(url) {
            apply(cached)
            return
        }
        Task { @MainActor [weak self] in
            guard let image = await ImageLoader.shared.image(for: url) else { return }
            self?.apply(image)
            self?.onLoad?()
        }
    }

    private func apply(_ image: PlatformImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let width = min(maxWidth, max(size.width, maxWidth * 0.5))
        aspect = size.height / size.width
        self.image = image
        bounds = CGRect(x: 0, y: 0, width: width, height: min(width * aspect, maxWidth * 1.3))
    }

    private static func placeholder(tint: PlatformColor) -> PlatformImage {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9))
        return renderer.image { ctx in
            tint.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        #else
        let image = NSImage(size: NSSize(width: 16, height: 9))
        image.lockFocus()
        tint.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 9).fill()
        image.unlockFocus()
        return image
        #endif
    }
}

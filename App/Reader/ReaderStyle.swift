import ReadAloudKit
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

/// Reader typography and highlight preferences.
struct ReaderStyle: Equatable {
    enum Typeface: String, CaseIterable, Identifiable {
        case serif, sans, rounded
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serif: "New York"
            case .sans: "San Francisco"
            case .rounded: "Rounded"
            }
        }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system, paper, night
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "Automatic"
            case .paper: "Paper"
            case .night: "Night"
            }
        }
    }

    enum HighlightMode: String, CaseIterable, Identifiable {
        case wordAndSentence, sentence, word, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wordAndSentence: "Word and sentence"
            case .sentence: "Sentence only"
            case .word: "Word only"
            case .none: "Off"
            }
        }
        var showsSentence: Bool { self == .wordAndSentence || self == .sentence }
        var showsWord: Bool { self == .wordAndSentence || self == .word }
    }

    var fontSize: CGFloat = 19
    var typeface: Typeface = .serif
    var theme: Theme = .system
    var highlight: HighlightMode = .wordAndSentence
    var lineSpacing: CGFloat = 1.45
    var maxLineWidth: CGFloat = 680
    /// Resolved light/dark for `.system`.
    var isDark = false

    // MARK: Colors

    var background: PlatformColor {
        switch theme {
        case .paper: PlatformColor(red: 0.973, green: 0.953, blue: 0.914, alpha: 1)
        case .night: PlatformColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        case .system: isDark ? PlatformColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : PlatformColor(white: 1, alpha: 1)
        }
    }

    var effectiveDark: Bool { theme == .night || (theme == .system && isDark) }

    var text: PlatformColor {
        switch theme {
        case .paper: PlatformColor(red: 0.20, green: 0.17, blue: 0.13, alpha: 1)
        default: effectiveDark ? PlatformColor(white: 0.90, alpha: 1) : PlatformColor(white: 0.10, alpha: 1)
        }
    }

    var secondaryText: PlatformColor {
        switch theme {
        case .paper: PlatformColor(red: 0.45, green: 0.40, blue: 0.33, alpha: 1)
        default: effectiveDark ? PlatformColor(white: 0.60, alpha: 1) : PlatformColor(white: 0.42, alpha: 1)
        }
    }

    /// Accent used by both highlights: the app's signature muted salmon (see `Color.signature`), a touch lighter on
    /// dark backgrounds and a touch warmer on paper so the fills still read as a marker.
    var accent: PlatformColor {
        switch theme {
        case .paper: PlatformColor(red: 0.76, green: 0.44, blue: 0.37, alpha: 1)
        default: effectiveDark ? PlatformColor(red: 0.83, green: 0.53, blue: 0.49, alpha: 1)
                               : PlatformColor(red: 0.78, green: 0.47, blue: 0.41, alpha: 1)
        }
    }

    var sentenceFill: PlatformColor { accent.withAlphaComponent(effectiveDark ? 0.16 : 0.13) }
    var wordFill: PlatformColor { accent.withAlphaComponent(effectiveDark ? 0.45 : 0.36) }
    var codeBackground: PlatformColor { effectiveDark ? PlatformColor(white: 1, alpha: 0.06) : PlatformColor(white: 0, alpha: 0.045) }
    var link: PlatformColor { effectiveDark ? PlatformColor(red: 0.55, green: 0.72, blue: 1, alpha: 1) : PlatformColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 1) }

    // MARK: Fonts

    func font(size: CGFloat, weight: PlatformFont.Weight = .regular, italic: Bool = false) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        #if os(iOS)
        var descriptor = base.fontDescriptor
        switch typeface {
        case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
        case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case .sans: break
        }
        if italic, let d = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) { descriptor = d }
        return PlatformFont(descriptor: descriptor, size: size)
        #else
        var descriptor = base.fontDescriptor
        switch typeface {
        case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
        case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case .sans: break
        }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return PlatformFont(descriptor: descriptor, size: size) ?? base
        #endif
    }

    func monospaced(size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Persists the reader style with @AppStorage-friendly raw values.
@MainActor
@Observable
final class ReaderPreferences {
    static let shared = ReaderPreferences()

    var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "reader.fontSize") } }
    var typeface: ReaderStyle.Typeface { didSet { UserDefaults.standard.set(typeface.rawValue, forKey: "reader.typeface") } }
    var theme: ReaderStyle.Theme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "reader.theme") } }
    var highlight: ReaderStyle.HighlightMode { didSet { UserDefaults.standard.set(highlight.rawValue, forKey: "reader.highlight") } }
    var autoScroll: Bool { didSet { UserDefaults.standard.set(autoScroll, forKey: "reader.autoScroll") } }

    init() {
        let d = UserDefaults.standard
        #if os(iOS)
        let defaultSize = 19.0
        #else
        let defaultSize = 18.0
        #endif
        fontSize = d.object(forKey: "reader.fontSize") as? Double ?? defaultSize
        typeface = d.string(forKey: "reader.typeface").flatMap(ReaderStyle.Typeface.init) ?? .serif
        theme = d.string(forKey: "reader.theme").flatMap(ReaderStyle.Theme.init) ?? .system
        highlight = d.string(forKey: "reader.highlight").flatMap(ReaderStyle.HighlightMode.init) ?? .wordAndSentence
        autoScroll = d.object(forKey: "reader.autoScroll") as? Bool ?? true
    }

    func style(isDark: Bool) -> ReaderStyle {
        ReaderStyle(fontSize: fontSize, typeface: typeface, theme: theme, highlight: highlight, isDark: isDark)
    }

    var colorSchemeOverride: ColorScheme? {
        switch theme {
        case .night: .dark
        case .paper: .light
        case .system: nil
        }
    }
}

extension ShapeStyle where Self == Color {
    /// The app's signature color: a desaturated, slightly deep salmon (AccentColor asset, lighter in dark mode).
    static var signature: Color { Color("AccentColor") }
}

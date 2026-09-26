import Foundation
import os
import UniformTypeIdentifiers

/// What a drag-and-drop (or share) carried, once resolved.
public enum DroppedItem: Equatable, Sendable {
    case webURL(URL)
    case fileURL(URL)
    case text(String)
}

/// Turns dropped `NSItemProvider`s into a link, file or text.
///
/// Browsers put several representations on a link drag (the URL, its title as plain text, sometimes HTML or
/// a webarchive), and loading one of them can fail while another works — so every representation is tried,
/// best first, and a link found inside dropped text still counts.
@MainActor
public enum DropResolver {
    nonisolated static let log = Logger(subsystem: "com.legitimateapps.ReadAnythingAloud", category: "drop")

    public static func resolve(_ providers: [NSItemProvider]) async -> DroppedItem? {
        var fallbackText: String?
        for provider in providers {
            log.info("drop types: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
            if let file = await fileURL(from: provider) { return .fileURL(file) }
            if let url = await webURL(from: provider) { return .webURL(url) }
            if let text = await text(from: provider) {
                if let url = linkIn(text) { return .webURL(url) }
                fallbackText = fallbackText ?? text
            }
        }
        if let fallbackText { return .text(fallbackText) }
        log.error("drop: nothing usable in \(providers.count) item(s)")
        return nil
    }

    // MARK: - Representations

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        if let data = await data(provider, UTType.fileURL),
           let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            return url
        }
        if let url = await loadURL(provider), url.isFileURL { return url }
        return nil
    }

    private static func webURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider), isWeb(url) { return url }
            if let data = await data(provider, UTType.url) {
                if let url = URL(dataRepresentation: data, relativeTo: nil), isWeb(url) { return url }
                if let string = String(data: data, encoding: .utf8), let url = linkIn(string) { return url }
            }
        }
        // Rich drags (HTML, webarchive) often still carry the link; take the first one found.
        for type in [UTType.html] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(provider, type), let html = String(data: data, encoding: .utf8),
               let url = firstHref(in: html) {
                return url
            }
        }
        return nil
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        if let string = await loadString(provider) { return string }
        for type in [UTType.utf8PlainText, UTType.plainText, UTType.text]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(provider, type), let string = String(data: data, encoding: .utf8) { return string }
        }
        return nil
    }

    // MARK: - Helpers

    nonisolated static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    /// A web link in free text: the whole string, a bare domain, or the first link inside it.
    public nonisolated static func linkIn(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), isWeb(url) { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector?.matches(in: trimmed, range: range) ?? [] {
            if let url = match.url, isWeb(url) { return url }
        }
        return nil
    }

    nonisolated static func firstHref(in html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: href), isWeb(url) { return url }
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { value, error in
                if let error { log.info("drop: URL load failed: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: value)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { value, error in
                if let error { log.info("drop: String load failed: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: value)
            }
        }
    }

    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { log.info("drop: \(type.identifier, privacy: .public) data failed: \(error.localizedDescription, privacy: .public)") }
                continuation.resume(returning: data)
            }
        }
    }
}

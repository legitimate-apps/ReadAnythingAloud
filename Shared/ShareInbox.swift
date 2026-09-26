import Foundation

/// Pages shared from other apps. The Share extension can't run the extractor (web views and the memory budget of
/// an extension don't mix), so it drops one small JSON file per share into the App Group container and the app
/// imports them the next time it becomes active.
struct SharedPage: Codable, Sendable {
    var url: URL?
    var title: String?
    /// The page as Safari rendered it (preprocessing JavaScript), which includes content behind the user's login.
    var html: String?
    /// Selected or shared plain text.
    var text: String?
    var date = Date()
}

enum ShareInbox {
    static let appGroup = "group.com.legitimateapps.ReadAnythingAloud"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    static func post(_ page: SharedPage) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(page)
        try data.write(to: directory.appending(path: "\(UUID().uuidString).json"), options: .atomic)
    }

    /// Removes and returns every waiting share, oldest first.
    static func drain() -> [SharedPage] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let pages = files.filter { $0.pathExtension == "json" }.compactMap { file -> SharedPage? in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(SharedPage.self, from: data)
        }
        return pages.sorted { $0.date < $1.date }
    }
}

import SwiftUI

/// Loads remote images once per URL with an identifying User-Agent (some image hosts reject anonymous clients),
/// shares in-flight requests, and keeps decoded images in memory and responses on disk.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "ReadAnythingAloud/1.0 (+https://github.com/legitimate-apps/ReadAnythingAloud)"]
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 150 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        cache.countLimit = 200
    }

    func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> PlatformImage? {
        if let image = cached(url) { return image }
        if let task = inFlight[url] { return await task.value }
        let session = session
        let task = Task<PlatformImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return PlatformImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A square-cropped remote image with a quiet placeholder; survives the frequent redraws of a playing row.
struct RemoteImage: View {
    let url: URL
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                #if os(iOS)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .task(id: url) {
            image = ImageLoader.shared.cached(url)
            if image == nil { image = await ImageLoader.shared.image(for: url) }
        }
    }
}

import CoreGraphics
import Foundation
import ImageIO

/// Decoded album artwork, memoised: `NowPlaying.artwork` bytes → `CGImage` once per distinct artwork,
/// never per frame. A small LRU (4 entries) keyed by the bytes themselves (length checked first, then a
/// full compare), so a re-sent identical artwork in a fresh `Data` is still a hit. Undecodable bytes are
/// remembered as nil so they are not retried every frame.
///
/// This is the one piece of state `RootView` reads besides its inputs; it only changes what is cached,
/// never what is drawn.
final class ArtworkCache: @unchecked Sendable {
    typealias Decoder = (Data) -> CGImage?

    static let shared = ArtworkCache()
    /// Largest decoded side (px): the art box is 340 px at render scale 1.
    static let maxPixelSize = 400

    private let capacity: Int
    private let decoder: Decoder
    private let lock = NSLock()
    /// Most recently used last.
    private var entries: [(data: Data, image: CGImage?)] = []

    init(capacity: Int = 4, decode: @escaping Decoder = ArtworkCache.decode) {
        self.capacity = capacity
        self.decoder = decode
    }

    func image(for data: Data) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.data.count == data.count && $0.data == data }) {
            let e = entries.remove(at: i)
            entries.append(e)
            return e.image
        }
        let img = decoder(data)
        entries.append((data, img))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return img
    }

    /// Downsampled artwork (ImageIO thumbnail ≤ `maxPixelSize`) converted once to 8-bit sRGB, or nil.
    /// Apple Music art often embeds a display profile ("Color LCD"); drawn as is, every frame paid a 16-bit
    /// colour conversion (~8 ms/frame), so the conversion happens here, once per track.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        return ctx.makeImage()
    }
}

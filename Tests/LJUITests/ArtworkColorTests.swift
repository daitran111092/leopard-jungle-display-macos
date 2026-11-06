import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LJUI

/// Apple Music artwork often embeds a display profile ("Color LCD") instead of sRGB. Left as is, every frame
/// pays a 16-bit colour conversion of the art (~8 ms/frame measured with `sample`: vTransformTRCParametric).
/// The cache must hand out 8-bit sRGB so the per-frame draw is a plain blit.
@Test func artworkIsDecodedToEightBitSRGB() throws {
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let ctx = try #require(CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 16, bytesPerRow: 0, space: p3,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
    ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0.2, 0.6, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
    let out = NSMutableData()
    let dst = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dst, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dst))

    let img = try #require(ArtworkCache.decode(out as Data))
    #expect(img.bitsPerComponent == 8)
    #expect(img.colorSpace?.name == CGColorSpace.sRGB)
    #expect(max(img.width, img.height) <= ArtworkCache.maxPixelSize)
}

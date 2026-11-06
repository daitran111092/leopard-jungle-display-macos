import Testing
import Foundation
import CoreGraphics
import ImageIO
import LJCore
@testable import LJUI

private func solid(_ w: Int, _ h: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

@Suite struct FrameEncoderTests {
    @Test(arguments: [true, false])
    func rotationMapsCorners(hardware: Bool) throws {
        // CG origin is bottom-left; "top" = high y.
        let src = solid(1920, 462) { c in
            c.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1920, height: 462))
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 462 - 100, width: 100, height: 100))      // top-left
            c.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 1820, y: 462 - 100, width: 100, height: 100))   // top-right
            c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))              // bottom-left
        }
        var budget = FrameBudget()
        let enc = FrameEncoder(hardware: hardware)
        #expect(enc.isHardware == hardware) // libjpeg-turbo is linked statically
        let data = try #require(enc.encode(src, budget: &budget))
        #expect(data.prefix(2) == Data([0xff, 0xd8]) && data.suffix(2) == Data([0xff, 0xd9]))
        let s = CGImageSourceCreateWithData(data as CFData, nil)!
        let out = CGImageSourceCreateImageAtIndex(s, 0, nil)!
        #expect(out.width == 462 && out.height == 1920)
        let g = pixel(out, 30, 30)            // top-left
        #expect(g.1 > 180 && g.0 < 80 && g.2 < 80)
        let r = pixel(out, 30, 1890)          // bottom-left
        #expect(r.0 > 180 && r.1 < 80 && r.2 < 80)
        let b = pixel(out, 430, 1890)         // bottom-right
        #expect(b.2 > 180 && b.0 < 80 && b.1 < 80)
    }

    @Test(arguments: [true, false])
    func encodePerformance(hardware: Bool) {
        let src = solid(1920, 462) { c in
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<1500 {
                c.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1))
                c.fill(CGRect(x: .random(in: 0...1900, using: &rng), y: .random(in: 0...440, using: &rng), width: .random(in: 5...120, using: &rng), height: .random(in: 5...60, using: &rng)))
            }
        }
        let enc = FrameEncoder(hardware: hardware)
        var budget = FrameBudget()
        for _ in 0..<10 { _ = enc.encode(src, budget: &budget) }
        let n = 60
        let t0 = DispatchTime.now().uptimeNanoseconds
        var bytes = 0
        for _ in 0..<n { bytes += enc.encode(src, budget: &budget)?.count ?? 0 }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
        print("encodePerformance(hardware: \(hardware)): avg \(ms) ms/frame, avg \(bytes / n / 1024) KB, q \(budget.q)")
        #expect(ms < 12)
    }

    /// VT must not shift the Jinx brand colours (needs 601 matrix / sRGB attachments on the pixel buffer).
    @Test(arguments: [true, false])
    func brandColoursSurviveEncoding(hardware: Bool) throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let colours: [(Int, Int, Int)] = [(0xff, 0x2e, 0xaa), (0x4f, 0xb6, 0xff)]
        let ctx = CGContext(data: nil, width: 1920, height: 462, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (i, c) in colours.enumerated() {
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [CGFloat(c.0) / 255, CGFloat(c.1) / 255, CGFloat(c.2) / 255, 1])!)
            ctx.fill(CGRect(x: i * 960, y: 0, width: 960, height: 462))
        }
        var budget = FrameBudget()
        let data = try #require(FrameEncoder(hardware: hardware).encode(ctx.makeImage()!, budget: &budget))
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        var px = [UInt8](repeating: 0, count: 462 * 1920 * 4)
        let out = CGContext(data: &px, width: 462, height: 1920, bitsPerComponent: 8, bytesPerRow: 462 * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        out.draw(img, in: CGRect(x: 0, y: 0, width: 462, height: 1920))
        // Portrait (CCW): landscape x = 0 is the bottom; rows are top-first in memory.
        for (i, c) in colours.enumerated() {
            let row = 1920 - 1 - (i * 960 + 480), o = (row * 462 + 231) * 4
            let got = (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
            #expect(abs(got.0 - c.0) <= 6 && abs(got.1 - c.1) <= 6 && abs(got.2 - c.2) <= 6, "\(c) -> \(got)")
        }
    }

    /// A dead hardware session: frames are skipped (nil — the panel keeps its last image), the session is
    /// recreated after every `maxHardwareFailures` consecutive failures, and ImageIO output never reaches the
    /// panel (the firmware hangs on ImageIO JPEGs: restart markers + APP1/APP13, verified on the device).
    @Test func failingHardwareSkipsFramesAndNeverFallsBackToImageIO() throws {
        let src = solid(1920, 462) { c in
            c.setFillColor(CGColor(red: 1, green: 0.18, blue: 0.67, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1920, height: 462))
        }
        let calls = Counter(), made = Counter()
        var events: [String] = []
        let enc = FrameEncoder(hardwareFactory: {
            made.n += 1
            return { _, _ in calls.n += 1; return .failure(.init(status: -12902)) }
        }, log: { events.append($0) })
        var budget = FrameBudget()
        let q0 = budget.q
        for _ in 0..<20 { #expect(enc.encode(src, budget: &budget) == nil) }
        #expect(calls.n == 20)
        #expect(made.n == 1 + 20 / FrameEncoder.maxHardwareFailures)   // recreated after every 3 failures
        #expect(budget.q == q0)
        #expect(events.contains { $0.contains("-12902") })
    }

    @Test func hardwareRecoversAfterRecreation() throws {
        let src = solid(1920, 462) { _ in }
        let made = Counter()
        let enc = FrameEncoder(hardwareFactory: {
            made.n += 1
            let ok = made.n > 1
            return { _, _ in ok ? .success(Data([0xff, 0xd8, 0xff, 0xd9])) : .failure(.init(status: -1)) }
        })
        var budget = FrameBudget()
        for _ in 0..<FrameEncoder.maxHardwareFailures { #expect(enc.encode(src, budget: &budget) == nil) }
        #expect(made.n == 2)
        #expect(enc.encode(src, budget: &budget) == Data([0xff, 0xd8, 0xff, 0xd9]))
    }
}

private final class Counter: @unchecked Sendable { var n = 0 }

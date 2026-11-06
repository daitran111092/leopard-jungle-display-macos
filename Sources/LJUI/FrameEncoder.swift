import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import CTurboJPEG
import LJCore

/// Rotates a landscape frame 90 degrees (CCW, or CW with the `rotateCW` default for a panel mounted upside down)
/// and JPEG-encodes it, within the frame budget.
///
/// Pipeline:
/// 1. draw the landscape image unrotated into a reused sRGB bitmap (this is where SwiftUI's lazy
///    `ImageRenderer` image is rasterised; an unrotated same-format draw is a fast blit),
/// 2. `vImageRotate90_ARGB8888` into a reused BGRA `CVPixelBuffer`, then swizzle RGBX → BGRX in place
///    (~0.1 ms together; a rotated CGContext draw costs ~3 ms),
/// 3. baseline 4:2:0 JPEG via libjpeg-turbo (the encoder family the vendor app uses; ~5–8 ms at q 0.95).
///
/// Panel safety: the panel firmware hangs (display stuck, needs a power cycle) on ImageIO JPEGs (APP1/APP13
/// metadata; libjpeg-turbo's plain JFIF output is fine). So with `hardware: true` (the panel path) ImageIO output
/// is never returned: a failed frame yields nil (skip; the panel keeps its last image), every failure is logged,
/// and the compressor is recreated after every `maxHardwareFailures` consecutive failures. `hardware: false`
/// (tests, fixture PNGs) uses ImageIO only.
public final class FrameEncoder {
    private let width: Int
    private let height: Int
    private let landscape: CGContext
    private let portrait: CVPixelBuffer
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    /// A panel-encoder failure, with its status (libjpeg-turbo returns -1; 0 when it produced no data).
    struct HardwareError: Error { let status: Int32 }
    /// One synchronous panel JPEG of the portrait buffer at quality q.
    typealias HardwareEncode = (CVPixelBuffer, Double) -> Result<Data, HardwareError>

    public static let maxHardwareFailures = 3

    private let hardwareFactory: (() -> HardwareEncode?)?
    private var hardware: HardwareEncode?
    private let useImageIO: Bool
    private let log: (String) -> Void
    private var failures = 0
    /// `defaults write vn.kahn.ljdisplay rotateCW -bool YES`: the panel is mounted upside down.
    private let rotation = UInt8(UserDefaults.standard.bool(forKey: "rotateCW") ? kRotate90DegreesClockwise
                                                                              : kRotate90DegreesCounterClockwise)

    /// R,G,B,X bytes in sRGB: the native layout of `ImageRenderer` output, so step 1 is a plain copy
    /// (a BGRA target made CoreGraphics convert every pixel).
    static let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    /// The portrait pixel buffer is BGRA, swizzled after the rotate.
    private static let rgbxToBGRX: [UInt8] = [2, 1, 0, 3]

    /// `hardware: true` (panel): libjpeg-turbo only, never ImageIO. `hardware: false`: ImageIO only (tests, PNGs).
    /// `log` receives encoder failure / recovery lines (wire it to the app log).
    public convenience init(width: Int = 1920, height: Int = 462, hardware: Bool = true,
                            log: @escaping (String) -> Void = { _ in }) {
        self.init(width: width, height: height,
                  hardwareFactory: hardware ? { TurboJPEG().map { tj in tj.encode } } : nil,
                  log: log)
    }

    /// Test seam: `hardwareFactory` builds the hardware encoder (nil → unavailable). A non-nil factory means the
    /// panel path (no ImageIO); nil means ImageIO only.
    init(width: Int = 1920, height: Int = 462, hardwareFactory: (() -> HardwareEncode?)?,
         log: @escaping (String) -> Void = { _ in }) {
        self.width = width
        self.height = height
        self.hardwareFactory = hardwareFactory
        self.useImageIO = hardwareFactory == nil
        self.log = log
        landscape = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: Self.bitmapInfo)!
        landscape.interpolationQuality = .none
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, height, width, kCVPixelFormatType_32BGRA, nil, &pb)
        portrait = pb!
        hardware = hardwareFactory?()
    }

    /// True when frames go through the libjpeg-turbo panel encoder.
    public var isHardware: Bool { hardware != nil }

    /// The rotated JPEG, or nil if encoding failed (nothing should be pushed).
    public func encode(_ image: CGImage, budget: inout FrameBudget) -> Data? {
        landscape.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let src = landscape.data else { return nil }
        CVPixelBufferLockBaseAddress(portrait, [])
        var s = vImage_Buffer(data: src, height: vImagePixelCount(height), width: vImagePixelCount(width),
                              rowBytes: landscape.bytesPerRow)
        var d = vImage_Buffer(data: CVPixelBufferGetBaseAddress(portrait), height: vImagePixelCount(width),
                              width: vImagePixelCount(height), rowBytes: CVPixelBufferGetBytesPerRow(portrait))
        var bg: [UInt8] = [0, 0, 0, 0]
        let rot = vImageRotate90_ARGB8888(&s, &d, rotation, &bg, vImage_Flags(kvImageNoFlags))
        let perm = vImagePermuteChannels_ARGB8888(&d, &d, Self.rgbxToBGRX, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(portrait, [])
        guard rot == kvImageNoError, perm == kvImageNoError else { return nil }
        if useImageIO { return budget.encode { q in imageIOJPEG(q) } }
        return budget.encode { q in hardwareJPEG(q) }
    }

    // MARK: hardware failure policy

    private func hardwareJPEG(_ q: Double) -> Data? {
        if hardware == nil { recreateHardware() }
        guard let hw = hardware else { return nil }
        switch hw(portrait, q) {
        case .success(let d) where !d.isEmpty:
            if failures > 0 { log("encoder: hardware JPEG recovered after \(failures) failure(s)") }
            failures = 0
            return d
        case .success:
            fail(status: 0)
        case .failure(let e):
            fail(status: e.status)
        }
        return nil
    }

    private func fail(status: Int32) {
        failures += 1
        log("encoder: hardware JPEG failed (status \(status), \(failures) in a row) — frame skipped")
        if failures % Self.maxHardwareFailures == 0 { recreateHardware() }
    }

    private func recreateHardware() {
        hardware = hardwareFactory?()
        log("encoder: hardware JPEG session \(hardware == nil ? "unavailable" : "recreated")")
    }

    // MARK: ImageIO (tests / fixture PNGs only — never sent to the panel)

    private func imageIOJPEG(_ q: Double) -> Data? {
        CVPixelBufferLockBaseAddress(portrait, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(portrait, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(portrait),
              let ctx = CGContext(data: base, width: height, height: width, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(portrait), space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let rotated = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, rotated, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dst), out.length > 0 else { return nil }
        return out as Data
    }
}

/// A libjpeg-turbo compressor: baseline Huffman, 4:2:0, JFIF only (no restart markers, no APP1/APP13).
final class TurboJPEG {
    private let handle: tjhandle

    init?() {
        guard let h = tj3InitVersion(Int32(TJINIT_COMPRESS.rawValue), TURBOJPEG_VERSION_NUMBER) else { return nil }
        tj3Set(h, Int32(TJPARAM_SUBSAMP.rawValue), TJSAMP_420.rawValue)
        handle = h
    }

    deinit { tj3Destroy(handle) }

    /// JPEG of a BGRX pixel buffer at quality q (0…1).
    func encode(_ buffer: CVPixelBuffer, _ q: Double) -> Result<Data, FrameEncoder.HardwareError> {
        tj3Set(handle, Int32(TJPARAM_QUALITY.rawValue), Int32((q * 100).rounded()))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .failure(.init(status: 0)) }
        var out: UnsafeMutablePointer<UInt8>?
        var size = 0
        let st = tj3Compress8(handle, base.assumingMemoryBound(to: UInt8.self),
                              Int32(CVPixelBufferGetWidth(buffer)), Int32(CVPixelBufferGetBytesPerRow(buffer)),
                              Int32(CVPixelBufferGetHeight(buffer)), Int32(TJPF_BGRX.rawValue), &out, &size)
        defer { tj3Free(out) }
        guard st == 0, let out, size > 0 else { return .failure(.init(status: st)) }
        return .success(Data(bytes: out, count: size))
    }
}

/// Renders a SwiftUI view to a `CGImage` at scale 1. (`ImageRenderer.cgImage` beats drawing through
/// `render(rasterizationScale:renderer:)` into a reused CGContext: 1–2 ms vs 4–6 ms per frame measured.)
@MainActor
public final class ViewRenderer<V: View> {
    private let renderer: ImageRenderer<V>

    public init(size: CGSize, initial: V) {
        renderer = ImageRenderer(content: initial)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(size)
    }

    public func render(_ view: V) -> CGImage {
        renderer.content = view
        return renderer.cgImage!
    }
}

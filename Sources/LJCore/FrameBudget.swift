import Foundation

/// Adaptive JPEG quality controller keeping each frame under a byte budget.
///
/// Steps quality down until the frame fits (floor `minQ`), and up by one step when a frame is far under
/// budget. A quality that overflowed becomes a ceiling for `ceilingHold` frames, so an encoder whose size
/// jumps between steps (VideoToolbox did: q 0.60 → 46 KB, 0.65 → 100+ KB) settles instead of encoding every
/// frame twice; after the hold the higher quality is tried again (content may have become simpler).
public struct FrameBudget: Sendable {
    public var maxBytes = 90 * 1024
    public var minQ = 0.40
    public var maxQ = 0.90
    public var step = 0.05
    public private(set) var q = 0.80
    /// Frames an overflowing quality stays off-limits.
    public static let ceilingHold = 120

    private var ceiling: Double?
    private var hold = 0

    public init() {}

    private func quantize(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Encodes at the current quality, stepping it as needed. `enc` returning nil or empty data is a
    /// failure: the result is nil and the quality is not raised (an empty frame is not "far under budget").
    public mutating func encode(_ enc: (Double) -> Data?) -> Data? {
        guard var data = enc(q), !data.isEmpty else { return nil }
        if hold > 0 { hold -= 1 } else { ceiling = nil }
        while data.count > maxBytes && quantize(q - step) >= minQ {
            ceiling = q
            hold = Self.ceilingHold
            q = quantize(q - step)
            guard let d = enc(q), !d.isEmpty else { return nil }
            data = d
        }
        let up = min(maxQ, quantize(q + step))
        if Double(data.count) < 0.7 * Double(maxBytes), up < (ceiling ?? .infinity) - 1e-9 {
            q = up
        }
        return data
    }
}

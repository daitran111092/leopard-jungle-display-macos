import Foundation

/// FiiO K7 sample-rate LED class: cyan ≤ 48 kHz, yellow above, green for DSD.
public enum RateClass: Equatable, Sendable { case standard, hiRes, dsd }

/// ≤ 48 000 Hz → `.standard`; > 48 000 Hz → `.hiRes`; `isDSD` → `.dsd` (whatever the rate).
public func rateClass(sampleRate: Double, isDSD: Bool = false) -> RateClass {
    if isDSD { return .dsd }
    return sampleRate > 48_000 ? .hiRes : .standard
}

/// "44.1 kHz", "96 kHz", "352.8 kHz"; with bits "96 kHz · 24-bit".
public func fmtAudioFormat(sampleRate: Double, bitDepth: Int?) -> String {
    let tenths = (sampleRate / 100).rounded()   // kHz × 10
    let khz = tenths.truncatingRemainder(dividingBy: 10) == 0
        ? String(format: "%.0f", tenths / 10) : String(format: "%.1f", tenths / 10)
    let rate = "\(khz) kHz"
    guard let bitDepth, bitDepth > 0 else { return rate }
    return "\(rate) · \(bitDepth)-bit"
}

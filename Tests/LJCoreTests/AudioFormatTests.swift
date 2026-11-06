import Testing
@testable import LJCore

@Suite struct AudioFormatTests {
    @Test func standardRatesUpTo48k() {
        #expect(rateClass(sampleRate: 44_100) == .standard)
        #expect(rateClass(sampleRate: 48_000) == .standard)
    }

    @Test func hiResAbove48k() {
        for r in [88_200.0, 96_000, 176_400, 192_000, 352_800, 384_000] {
            #expect(rateClass(sampleRate: r) == .hiRes)
        }
    }

    @Test func dsdWins() {
        #expect(rateClass(sampleRate: 176_400, isDSD: true) == .dsd)
        #expect(rateClass(sampleRate: 44_100, isDSD: true) == .dsd)
    }

    @Test func formatRate() {
        #expect(fmtAudioFormat(sampleRate: 44_100, bitDepth: nil) == "44.1 kHz")
        #expect(fmtAudioFormat(sampleRate: 48_000, bitDepth: nil) == "48 kHz")
        #expect(fmtAudioFormat(sampleRate: 96_000, bitDepth: nil) == "96 kHz")
        #expect(fmtAudioFormat(sampleRate: 176_400, bitDepth: nil) == "176.4 kHz")
        #expect(fmtAudioFormat(sampleRate: 352_800, bitDepth: nil) == "352.8 kHz")
    }

    @Test func formatRateAndBits() {
        #expect(fmtAudioFormat(sampleRate: 96_000, bitDepth: 24) == "96 kHz · 24-bit")
        #expect(fmtAudioFormat(sampleRate: 44_100, bitDepth: 16) == "44.1 kHz · 16-bit")
    }

    @Test func audioOutputFormatDefaultsNil() {
        let o = AudioOutput(name: "x", transport: .usb, isBuiltInSpeaker: false)
        #expect(o.sampleRate == nil && o.bitDepth == nil)
        let k7 = AudioOutput(name: "FiiO K7", transport: .usb, isBuiltInSpeaker: false, sampleRate: 96_000, bitDepth: 24)
        #expect(k7.sampleRate == 96_000 && k7.bitDepth == 24)
        #expect(k7 != o)
    }
}

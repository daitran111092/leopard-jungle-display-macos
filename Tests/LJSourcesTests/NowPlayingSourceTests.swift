import Testing
import Foundation
@testable import LJSources

@Suite struct NowPlayingLocateTests {
    /// Builds `<root>/<rel>/{bin/mediaremote-adapter.pl, MediaRemoteAdapter.framework/MediaRemoteAdapter}`.
    private func makeAdapter(in root: URL, _ rel: String) throws -> URL {
        let dir = root.appendingPathComponent(rel)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("MediaRemoteAdapter.framework"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("bin/mediaremote-adapter.pl"))
        try Data().write(to: dir.appendingPathComponent("MediaRemoteAdapter.framework/MediaRemoteAdapter"))
        return dir
    }

    @Test func prefersBundleResourcesThenRepoVendor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("np-locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Fake repo: <root>/repo/Sources/LJSources/NowPlayingSource.swift → <root>/repo/vendor/mediaremote-adapter
        let vendor = try makeAdapter(in: root, "repo/vendor/mediaremote-adapter")
        let fakeSource = root.appendingPathComponent("repo/Sources/LJSources/NowPlayingSource.swift").path
        let app = root.appendingPathComponent("X.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"),
                                                withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: app))

        #expect(NowPlayingSource.locateAdapter(bundle: bundle, filePath: fakeSource)?.standardizedFileURL
                == vendor.standardizedFileURL)
        let inApp = try makeAdapter(in: app, "Contents/Resources/mediaremote-adapter")
        #expect(NowPlayingSource.locateAdapter(bundle: bundle, filePath: fakeSource)?.standardizedFileURL
                == inApp.standardizedFileURL)
        // A script without a built framework is not an adapter dir.
        try FileManager.default.removeItem(at: inApp.appendingPathComponent("MediaRemoteAdapter.framework"))
        #expect(!NowPlayingSource.isAdapterDir(inApp))
    }
}

@Suite struct NowPlayingRestartTests {
    @Test func restartBacksOffToThirtySeconds() {
        var d = NowPlayingSource.minRestartDelay
        var seq: [Double] = []
        for _ in 0..<7 { seq.append(d); d = NowPlayingSource.nextRestartDelay(after: d) }
        #expect(seq == [1, 2, 4, 8, 16, 30, 30])
    }

    /// The watchdog wrapper is valid Perl (syntax check with the same /usr/bin/perl the source runs).
    @Test func watchdogCompiles() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-c", "-e", NowPlayingSource.watchdogScript]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}

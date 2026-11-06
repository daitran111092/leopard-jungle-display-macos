import Foundation

/// Locates LJUI's `Resources` folder (fonts, monkey.png).
///
/// SwiftPM's generated `Bundle.module` only looks next to the executable's *bundle URL* (for an `.app`
/// that is the bundle root, which codesign refuses to seal) and then at an absolute `.build` path that
/// only exists on the build machine — and it calls `fatalError` when both miss. So look in the places
/// an app or a CLI actually ships the resource bundle first, and fall back to `Bundle.module` only for
/// `swift run` / `swift test`.
public enum LJResources {
    public static let bundleName = "LJDisplay_LJUI.bundle"

    /// `…/LJDisplay_LJUI.bundle/Resources`.
    public static let url: URL? = {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName), // LJ Display.app/Contents/Resources
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName), // next to the binary
        ].compactMap { $0 }
        for c in candidates {
            let r = c.appendingPathComponent("Resources")
            if fm.fileExists(atPath: r.appendingPathComponent("Fonts").path) { return r }
        }
        return Bundle.module.url(forResource: "Resources", withExtension: nil)
    }()
}

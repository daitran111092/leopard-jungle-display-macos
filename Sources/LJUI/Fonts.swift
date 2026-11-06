import CoreText
import Foundation
import SwiftUI

/// Bundled fonts (OFL / Apache; the display face SVN-Road Rage is personal-use only, see its LICENSE.txt) (Sources/LJUI/Resources/Fonts), registered once per process.
///
/// Every face gets a CoreText cascade list ending in Be Vietnam Pro, so glyphs the display faces
/// lack (Rock Salt has no Vietnamese; the display face covers it fully) fall back to Be Vietnam Pro instead of
/// the system font.
public enum Fonts {
    public enum Face: String, CaseIterable, Sendable {
        case display = "SVN-RoadRage-Regular"
        case salt = "RockSalt-Regular"
        case chakra400 = "ChakraPetch-Regular"
        case chakra500 = "ChakraPetch-Medium"
        case chakra600 = "ChakraPetch-SemiBold"
        case chakra700 = "ChakraPetch-Bold"
        case vietnam400 = "BeVietnamPro-Regular"
        case vietnam600 = "BeVietnamPro-SemiBold"
    }

    /// Registers the bundled fonts (process scope). Idempotent; returns the PostScript names registered.
    @discardableResult
    public static func register() -> [String] { registered }

    private static let registered: [String] = {
        guard let root = LJResources.url?.appendingPathComponent("Fonts"),
              let it = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let url as URL in it where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                // Already registered (e.g. a second test process in the same host) is fine.
                _ = err?.takeRetainedValue()
            }
            names.append(url.deletingPathExtension().lastPathComponent)
        }
        return names.sorted()
    }()

    /// A CTFont for `face` at `size` with the Be Vietnam Pro cascade. Cached.
    public static func ctFont(_ face: Face, _ size: CGFloat) -> CTFont {
        _ = registered
        return cache.get(face, size)
    }

    private static let cache = FontCache()

    private final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [String: CTFont] = [:]
        private var swift: [String: Font] = [:]

        func get(_ face: Face, _ size: CGFloat) -> CTFont {
            let key = "\(face.rawValue)@\(size)"
            return lock.withLock {
                if let f = fonts[key] { return f }
                let f = make(face, size)
                fonts[key] = f
                return f
            }
        }

        func font(_ face: Face, _ size: CGFloat) -> Font {
            let key = "\(face.rawValue)@\(size)"
            if let f = lock.withLock({ swift[key] }) { return f }
            let f = Font(get(face, size))
            lock.withLock { swift[key] = f }
            return f
        }

        private func make(_ face: Face, _ size: CGFloat) -> CTFont {
            let fallback: Face = (face == .vietnam600 || face == .chakra600 || face == .chakra700) ? .vietnam600 : .vietnam400
            var attrs: [CFString: Any] = [kCTFontNameAttribute: face.rawValue]
            if face != fallback {
                attrs[kCTFontCascadeListAttribute] = [CTFontDescriptorCreateWithNameAndSize(fallback.rawValue as CFString, size)]
            }
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            return CTFontCreateWithFontDescriptor(desc, size, nil)
        }
    }

    static func font(_ face: Face, _ size: CGFloat) -> Font {
        _ = registered
        return cache.font(face, size)
    }
}

extension Font {
    /// SVN-Road Rage (display/title face, full Vietnamese).
    static func display(_ size: CGFloat) -> Font { Fonts.font(.display, size) }
    /// Rock Salt.
    static func salt(_ size: CGFloat) -> Font { Fonts.font(.salt, size) }
    /// Chakra Petch at CSS weight 400/500/600/700.
    static func chakra(_ size: CGFloat, _ weight: Int = 500) -> Font {
        let face: Fonts.Face = switch weight {
        case ..<450: .chakra400
        case ..<550: .chakra500
        case ..<650: .chakra600
        default: .chakra700
        }
        return Fonts.font(face, size)
    }
}

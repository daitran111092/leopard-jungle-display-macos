import Testing
import Carbon.HIToolbox
@testable import LJSources

@Suite struct HotKeysParseTests {
    private func parsed(_ s: String) -> [UInt32]? { HotKeys.parse(s).map { [$0.0, $0.1] } }
    private let ctrlOpt = UInt32(controlKey | optionKey)

    @Test func fKeys() {
        let codes = [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, c) in codes.enumerated() {
            #expect(parsed("F\(13 + i)") == [UInt32(c), 0])
            #expect(parsed("f\(13 + i)") == [UInt32(c), 0])
        }
    }

    @Test func shiftFKeys() {
        #expect(parsed("Shift+F18") == [UInt32(kVK_F18), UInt32(shiftKey)])
        #expect(parsed("shift+f19") == [UInt32(kVK_F19), UInt32(shiftKey)])
        #expect(parsed(" Shift + F13 ") == [UInt32(kVK_F13), UInt32(shiftKey)])
    }

    @Test func ctrlOptionKeys() {
        let want: [String: Int] = ["Left": kVK_LeftArrow, "Right": kVK_RightArrow, "Up": kVK_UpArrow,
                                   "Down": kVK_DownArrow, "Space": kVK_Space, "Return": kVK_Return,
                                   "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket]
        for (key, code) in want {
            #expect(parsed("Ctrl+Option+\(key)") == [UInt32(code), ctrlOpt], "\(key)")
            #expect(parsed("ctrl+option+\(key.lowercased())") == [UInt32(code), ctrlOpt], "\(key)")
        }
    }

    @Test func modifierAliasesAndOrder() {
        let left = [UInt32(kVK_LeftArrow), ctrlOpt]
        #expect(parsed("Control+Option+Left") == left)
        #expect(parsed("Ctrl+Opt+Left") == left)
        #expect(parsed("Ctrl+Alt+Left") == left)
        #expect(parsed("Option+Ctrl+Left") == left)
        #expect(parsed("CTRL+OPTION+SPACE") == [UInt32(kVK_Space), ctrlOpt])
    }

    @Test func invalidIsNil() {
        for s in ["", "F12", "F20", "A", "Left", "Space", "[", "Return", "Shift+Return", "Ctrl+Return", "Ctrl+Left", "Option+Left", "Shift+Left",
                  "Ctrl+Option+A", "Ctrl+Option+F13", "Ctrl+F13", "Cmd+F13", "Shift+Shift+F13",
                  "Ctrl+Option+Shift+Left", "Ctrl+Ctrl+Left", "Ctrl+Option+", "+F13", "Shift+", "Hyper+F13"] {
            #expect(HotKeys.parse(s) == nil, "\(s)")
        }
    }
}

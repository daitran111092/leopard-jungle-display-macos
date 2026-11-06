import Testing
import Foundation
import CoreAudio
import LJCore
@testable import LJSources

@Suite struct AudioHelpersTests {
    let ispk: UInt32 = 0x6973_706B // 'ispk'
    let hdpn: UInt32 = 0x6864_706E // 'hdpn'

    @Test func builtInWithSpeakerDataSourceIsFlagged() {
        #expect(isBuiltInSpeaker(transport: .builtin, dataSource: ispk, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"))
    }
    @Test func builtInHeadphoneDataSourceNotFlagged() {
        #expect(!isBuiltInSpeaker(transport: .builtin, dataSource: hdpn, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"))
    }
    @Test func noDataSourceFallsBackToUIDThenName() {
        #expect(isBuiltInSpeaker(transport: .builtin, dataSource: nil, uid: "BuiltInSpeakerDevice", name: "x"))
        #expect(isBuiltInSpeaker(transport: .builtin, dataSource: nil, uid: nil, name: "MacBook Pro Speakers"))
        #expect(!isBuiltInSpeaker(transport: .builtin, dataSource: nil, uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones"))
    }
    @Test func externalDevicesNeverFlagged() {
        #expect(!isBuiltInSpeaker(transport: .usb, dataSource: nil, uid: "AppleUSBAudioEngine:FiiO:K7", name: "FiiO K7"))
        #expect(!isBuiltInSpeaker(transport: .hdmi, dataSource: nil, uid: "x", name: "LG HDR 4K"))
        #expect(!isBuiltInSpeaker(transport: .bluetooth, dataSource: ispk, uid: "x", name: "AirPods Speaker"))
    }
    @Test func transportMapping() {
        #expect(transport(from: kAudioDeviceTransportTypeBuiltIn) == .builtin)
        #expect(transport(from: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(transport(from: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(transport(from: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(transport(from: kAudioDeviceTransportTypeHDMI) == .hdmi)
        #expect(transport(from: kAudioDeviceTransportTypeDisplayPort) == .hdmi)
        #expect(transport(from: kAudioDeviceTransportTypeAirPlay) == .airplay)
        #expect(transport(from: kAudioDeviceTransportTypeVirtual) == .other)
    }
}

@Suite struct SystemHelpersTests {
    @Test func outermostAppBundle() {
        let p = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(enclosingAppPath(p) == "/Applications/Google Chrome.app")
        #expect(enclosingAppPath("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") == "/System/Library/CoreServices/Finder.app")
        #expect(enclosingAppPath("/usr/local/bin/node") == nil)
        #expect(enclosingAppPath("/opt/my.application/bin/x") == nil)
    }
}

@Suite struct BluetoothParseTests {
    let json = """
    {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
      "device_connected":[
        {"MX Master 4":{"device_batteryLevelMain":"100%","device_minorType":"Mouse"}},
        {"AirPods Pro":{"device_batteryLevelLeft":"80%","device_batteryLevelRight":"74%","device_batteryLevelCase":"20%","device_minorType":"Headphones"}},
        {"Keychron K2":{"device_minorType":"Keyboard"}},
        {"Xbox Controller":{"device_batteryLevelMain":"55%","device_minorType":"Gamepad"}},
        {"JBL":{"device_minorType":"Speaker"}}
      ],
      "device_not_connected":[{"Galaxy Buds":{"device_minorType":"Headset"}}]}]}
    """

    @Test func parsesConnectedDevicesOnly() {
        let d = parseBluetoothProfiler(Data(json.utf8))
        #expect(d == [
            BtDevice(name: "MX Master 4", kind: .mouse, battery: 100),
            BtDevice(name: "AirPods Pro", kind: .headphones, batteryL: 80, batteryR: 74, batteryCase: 20),
            BtDevice(name: "Keychron K2", kind: .keyboard),
            BtDevice(name: "Xbox Controller", kind: .controller, battery: 55),
            BtDevice(name: "JBL", kind: .headphones),
        ])
    }
    @Test func garbageGivesEmpty() {
        #expect(parseBluetoothProfiler(Data("nope".utf8)).isEmpty)
        #expect(parseBluetoothProfiler(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)).isEmpty)
    }
}

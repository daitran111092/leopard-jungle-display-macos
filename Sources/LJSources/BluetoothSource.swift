import Foundation
import LJCore

/// Connected Bluetooth devices with battery levels.
///
/// Data path: `system_profiler SPBluetoothDataType -json` in a subprocess, parsed by `parseBluetoothProfiler`.
/// Chosen over IOBluetooth + IORegistry because, on macOS 26.6, (a) IOBluetooth in an unbundled CLI blocks on the
/// Bluetooth TCC permission, and (b) BLE devices (e.g. MX Master 4) carry no `BatteryPercent` in the IORegistry,
/// while system_profiler reports `device_batteryLevelMain/Left/Right/Case` for them. No permission is needed.
///
/// Without IOBluetooth there are no connect/disconnect notifications, so the source refreshes every `interval`
/// (default 30 s, spec §6) and whenever `refresh()` is called (e.g. when the audio output changes).
/// `onChange` runs on a private queue: once after `start()` and then whenever the device list changes.
public final class BluetoothSource: @unchecked Sendable {
    static let profilerTimeout: TimeInterval = 10

    private let onChange: @Sendable ([BtDevice]) -> Void
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "vn.kahn.ljdisplay.bluetooth")
    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var last: [BtDevice]?

    public init(interval: TimeInterval = 30, onChange: @escaping @Sendable ([BtDevice]) -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            last = nil
        }
    }

    /// Re-reads devices now (async).
    public func refresh() {
        queue.async { [self] in if timer != nil { poll() } }
    }

    private func poll() {
        guard let data = Self.runProfiler() else { return } // keep the last value on failure
        let devices = parseBluetoothProfiler(data)
        guard timer != nil, devices != last else { return }
        last = devices
        onChange(devices)
    }

    static func runProfiler() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + profilerTimeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// Parses `system_profiler SPBluetoothDataType -json`: the `device_connected` list only, in its order.
/// Battery strings look like `"80%"`. `device_minorType` → kind: Headphones/Headset/Speaker → headphones (audio),
/// Keyboard, Mouse/Trackpad, Gamepad/Joystick → controller, anything else → other.
func parseBluetoothProfiler(_ data: Data) -> [BtDevice] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
    var out: [BtDevice] = []
    for section in sections {
        for entry in section["device_connected"] as? [[String: Any]] ?? [] {
            for (name, value) in entry {
                let info = value as? [String: Any] ?? [:]
                func pct(_ key: String) -> Int? {
                    guard let s = info[key] as? String else { return nil }
                    return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
                }
                out.append(BtDevice(name: name, kind: btKind(info["device_minorType"] as? String),
                                    battery: pct("device_batteryLevelMain"),
                                    batteryL: pct("device_batteryLevelLeft"),
                                    batteryR: pct("device_batteryLevelRight"),
                                    batteryCase: pct("device_batteryLevelCase")))
            }
        }
    }
    return out
}

func btKind(_ minor: String?) -> BtKind {
    switch minor?.lowercased() ?? "" {
    case let m where m.contains("headphone") || m.contains("headset") || m.contains("speaker"): return .headphones
    case let m where m.contains("keyboard"): return .keyboard
    case let m where m.contains("mouse") || m.contains("trackpad"): return .mouse
    case let m where m.contains("gamepad") || m.contains("joystick") || m.contains("controller"): return .controller
    default: return .other
    }
}

import Foundation
import CoreAudio
import LJCore

/// Watches the system default output device with CoreAudio property listeners (no polling).
///
/// Listeners: the system object's default output device, and on the current device its name, transport type,
/// data source, volume (main element, plus channels 1/2 for devices without a main volume), nominal sample rate and
/// output stream list; on the device's first output stream its physical and virtual formats (bit depth). When the
/// default device (or its stream list) changes the listeners are moved to the new device / stream.
///
/// `onChange` runs on a private serial queue: once from `start()` and then whenever the computed `AudioOutput`
/// differs from the last one emitted. `nil` means no default output device.
public final class AudioSource: @unchecked Sendable {
    private let onChange: @Sendable (AudioOutput?) -> Void
    private let queue = DispatchQueue(label: "vn.kahn.ljdisplay.audio")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Confined to `queue`.
    private var running = false
    private var device: AudioObjectID = 0
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var stream: AudioObjectID = 0
    private var streamListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var last: AudioOutput??

    public init(onChange: @escaping @Sendable (AudioOutput?) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public func start() {
        onQueue {
            guard !running else { return }
            running = true
            var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                systemListener = block
            }
            defaultDeviceChanged()
        }
    }

    public func stop() {
        onQueue {
            guard running else { return }
            running = false
            if let block = systemListener {
                var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
                systemListener = nil
            }
            detachDevice()
            last = nil
        }
    }

    /// Runs `body` synchronously on `queue`, also when already on it (so `stop()` from `onChange` is safe).
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    // MARK: - Device tracking (on `queue`)

    private func defaultDeviceChanged() {
        guard running else { return }
        let id = Self.defaultOutputDevice()
        if id != device {
            detachDevice()
            device = id
            if id != 0 { attachDevice(id) }
        }
        emit()
    }

    private func attachDevice(_ id: AudioObjectID) {
        var addrs = [
            Self.address(kAudioObjectPropertyName),
            Self.address(kAudioDevicePropertyTransportType),
            Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
            Self.address(kAudioDevicePropertyNominalSampleRate),
        ]
        for el in [kAudioObjectPropertyElementMain, 1, 2] {
            addrs.append(Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: el))
        }
        for var a in addrs where AudioObjectHasProperty(id, &a) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.emit() }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr {
                deviceListeners.append((a, block))
            }
        }
        // Stream list changes (e.g. format/mode switch) move the bit-depth listeners to the new first stream.
        var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(id, &streams) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.streamsChanged() }
            if AudioObjectAddPropertyListenerBlock(id, &streams, queue, block) == noErr {
                deviceListeners.append((streams, block))
            }
        }
        attachStream(Self.firstOutputStream(id))
    }

    private func detachDevice() {
        detachStream()
        for (a, block) in deviceListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, block)
        }
        deviceListeners = []
        device = 0
    }

    private func streamsChanged() {
        guard running, device != 0 else { return }
        let s = Self.firstOutputStream(device)
        if s != stream { detachStream(); attachStream(s) }
        emit()
    }

    private func attachStream(_ id: AudioObjectID) {
        stream = id
        guard id != 0 else { return }
        for var a in [Self.address(kAudioStreamPropertyPhysicalFormat), Self.address(kAudioStreamPropertyVirtualFormat)]
        where AudioObjectHasProperty(id, &a) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.emit() }
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr {
                streamListeners.append((a, block))
            }
        }
    }

    private func detachStream() {
        for (a, block) in streamListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(stream, &a, queue, block)
        }
        streamListeners = []
        stream = 0
    }

    private func emit() {
        guard running else { return }
        let out = device == 0 ? nil : Self.read(device)
        if let last, last == out { return }
        last = .some(out)
        onChange(out)
    }

    /// Every device with output channels, evaluated as if it were the default output (diagnostics / ljprobe).
    public static func allOutputs() -> [(uid: String, output: AudioOutput)] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutputStreams).map { (readString($0, address(kAudioDevicePropertyDeviceUID)) ?? "?", read($0)) }
    }

    static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - CoreAudio reads

    static func address(_ sel: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(0)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != kAudioObjectUnknown ? id : 0
    }

    static func readUInt32(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func readFloat(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Float32? {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func readString(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    /// The device's first output stream, 0 when none.
    static func firstOutputStream(_ id: AudioObjectID) -> AudioObjectID {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= MemoryLayout<AudioObjectID>.size
        else { return 0 }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return 0 }
        return ids.first ?? 0
    }

    static func readFloat64(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Float64? {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func readASBD(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> AudioStreamBasicDescription? {
        var a = addr
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// Nominal sample rate (Hz); nil when unavailable or not positive.
    static func sampleRate(_ id: AudioObjectID) -> Double? {
        guard let r = readFloat64(id, address(kAudioDevicePropertyNominalSampleRate)), r > 0 else { return nil }
        return r
    }

    /// Bits per channel of the first output stream: physical format, else virtual format; nil when 0 / unavailable.
    static func bitDepth(_ id: AudioObjectID) -> Int? {
        let s = firstOutputStream(id)
        guard s != 0 else { return nil }
        for sel in [kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat] {
            if let f = readASBD(s, address(sel)), f.mBitsPerChannel > 0 { return Int(f.mBitsPerChannel) }
        }
        return nil
    }

    /// Main-element volume, else the mean of channels 1/2 that exist; nil when the device has no volume control.
    static func volume(_ id: AudioObjectID) -> Double? {
        let out = kAudioDevicePropertyScopeOutput
        if let v = readFloat(id, address(kAudioDevicePropertyVolumeScalar, scope: out)) { return Double(v) }
        let ch = [1, 2].compactMap { readFloat(id, address(kAudioDevicePropertyVolumeScalar, scope: out, element: $0)) }
        return ch.isEmpty ? nil : Double(ch.reduce(0, +)) / Double(ch.count)
    }

    static func read(_ id: AudioObjectID) -> AudioOutput {
        let name = readString(id, address(kAudioObjectPropertyName))?.trimmingCharacters(in: .whitespaces) ?? "Unknown output"
        let uid = readString(id, address(kAudioDevicePropertyDeviceUID))
        let tr = transport(from: readUInt32(id, address(kAudioDevicePropertyTransportType)) ?? 0)
        let ds = readUInt32(id, address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput))
        return AudioOutput(name: name, transport: tr, volume: volume(id),
                           isBuiltInSpeaker: isBuiltInSpeaker(transport: tr, dataSource: ds, uid: uid, name: name),
                           sampleRate: sampleRate(id), bitDepth: bitDepth(id))
    }
}

/// CoreAudio transport type → `Transport`. DisplayPort counts as `.hdmi` (monitor audio).
func transport(from raw: UInt32) -> Transport {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return .builtin
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
    case kAudioDeviceTransportTypeUSB: return .usb
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
    case kAudioDeviceTransportTypeAirPlay: return .airplay
    default: return .other
    }
}

/// "Built-in speakers" = transport built-in AND output data source `'ispk'` (spec §6).
/// Apple-silicon Macs expose the speakers and the headphone jack as separate devices, and the speaker device may
/// have no data-source property. Then the decision falls back to the device UID (`BuiltInSpeakerDevice`), and if
/// there's no UID, to a device name containing "Speaker". Non-built-in transports (USB DACs, HDMI/DP monitors,
/// Bluetooth) are never flagged.
func isBuiltInSpeaker(transport: Transport, dataSource: UInt32?, uid: String?, name: String) -> Bool {
    guard transport == .builtin else { return false }
    if let dataSource { return dataSource == 0x6973_706B } // 'ispk'
    if let uid { return uid.contains("BuiltInSpeaker") }
    return name.range(of: "speaker", options: .caseInsensitive) != nil
}

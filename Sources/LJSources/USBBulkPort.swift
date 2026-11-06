import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import LJCore

/// The panel's CDC data interface driven directly over IOUSBHost, bypassing the tty layer: every `write` is one
/// bulk OUT transfer, exactly like the vendor app on Windows (the macOS CDC tty splits a frame into ~1 KB
/// transfers, which this panel occasionally corrupts). No root needed while no one holds the tty open.
public final class USBBulkPort: PortIO, @unchecked Sendable {
    public static let vendorID = 0x33C3
    public static let productIDs = [0x7792, 0x7788]

    private let lock = NSLock()
    private var interface: IOUSBHostInterface?
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe
    private let writeTimeout: TimeInterval

    public init(writeTimeout: TimeInterval = SerialPort.defaultWriteTimeout) throws {
        self.writeTimeout = writeTimeout
        var found: (IOUSBHostInterface, IOUSBHostPipe, IOUSBHostPipe)?
        var lastError: Error = SerialPortError(op: "usb: panel not found", code: ENODEV)
        for pid in Self.productIDs where found == nil {
            let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            match["idVendor"] = Self.vendorID
            match["idProduct"] = pid
            let dev = IOServiceGetMatchingService(kIOMainPortDefault, match)
            guard dev != 0 else { continue }
            defer { IOObjectRelease(dev) }
            var kids: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(dev, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(kids) }
            while found == nil, case let svc = IOIteratorNext(kids), svc != 0 {
                defer { IOObjectRelease(svc) }
                guard IOObjectConformsTo(svc, "IOUSBHostInterface") != 0 else { continue }
                do {
                    let intf = try IOUSBHostInterface(__ioService: svc, options: [], queue: nil, interestHandler: nil)
                    // The CDC data interface: bulk OUT 0x01…0x0F and bulk IN 0x81…0x8F.
                    let out = (1...15).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
                    let inn = (0x81...0x8F).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
                    if let out, let inn { found = (intf, out, inn) } else { intf.destroy() }
                } catch {
                    lastError = error
                }
            }
        }
        guard let (intf, out, inn) = found else { throw lastError }
        interface = intf
        outPipe = out
        inPipe = inn
        // DTR on (CDC SET_CONTROL_LINE_STATE to interface 0), as the tty open does; best effort.
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x21
        req.bRequest = 0x22
        req.wValue = 0x0001
        req.wIndex = 0
        req.wLength = 0
        var n = 0
        try? intf.__send(req, data: nil, bytesTransferred: &n, completionTimeout: 1)
    }

    deinit { close() }

    private static let closedError = SerialPortError(op: "usb: port closed", code: EBADF)

    /// One bulk OUT transfer of the whole buffer (plus a zero-length packet when it ends on a packet boundary).
    public func write(_ d: Data) throws {
        guard lock.withLock({ interface != nil }) else { throw Self.closedError }
        let buf = NSMutableData(data: d)
        var n = 0
        do {
            try outPipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: writeTimeout)
        } catch {
            throw SerialPortError(op: "usb write (\(n)/\(d.count) bytes): \(error.localizedDescription)", code: EIO)
        }
        if d.count > 0, d.count % 512 == 0 {
            var z = 0
            try? outPipe.__sendIORequest(with: nil, bytesTransferred: &z, completionTimeout: writeTimeout)
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard lock.withLock({ interface != nil }) else { throw Self.closedError }
        let buf = NSMutableData(length: 4096)!
        var n = 0
        do {
            try inPipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: max(0.05, timeout))
        } catch let e as NSError where e.code == Int(kIOReturnTimeout) || e.code == Int(kIOReturnAborted) {
            return Data(bytes: buf.bytes, count: n)
        } catch {
            guard lock.withLock({ interface != nil }) else { throw Self.closedError }
            throw SerialPortError(op: "usb read: \(error.localizedDescription)", code: EIO)
        }
        return Data(bytes: buf.bytes, count: n)
    }

    public func close() {
        let i: IOUSBHostInterface? = lock.withLock { defer { interface = nil }; return interface }
        i?.destroy()
    }
}

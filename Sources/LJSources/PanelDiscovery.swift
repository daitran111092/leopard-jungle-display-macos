import Foundation
import IOKit

/// Watches IOKit for the panel's USB device (`IOUSBHostDevice`, `idVendor` 0x33c3, any PID) and reports its
/// `/dev/cu.*` callout path. Callbacks run on the main queue. `start()` also reports an already-present device.
public final class PanelDiscovery: @unchecked Sendable {
    public static let vendorID = 0x33c3
    /// The CDC serial node is published shortly after the USB device; poll for it this long.
    static let resolveAttempts = 20
    static let resolveInterval: TimeInterval = 0.25

    private let onAppear: (String) -> Void
    private let onDisappear: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    public init(onAppear: @escaping (String) -> Void, onDisappear: @escaping () -> Void) {
        self.onAppear = onAppear
        self.onDisappear = onDisappear
    }

    deinit { stop() }

    private static func matching() -> CFMutableDictionary {
        let d = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        // A bare `idVendor` key never matches IOUSBHostDevice (USB matching wants vendor+product);
        // IOPropertyMatch does a plain property compare, so any PID of this vendor matches.
        d[kIOPropertyMatchKey] = ["idVendor": vendorID]
        return d as CFMutableDictionary
    }

    /// Must be called on the main thread.
    public func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), { refcon, iter in
            guard let refcon else { return }
            Unmanaged<PanelDiscovery>.fromOpaque(refcon).takeUnretainedValue().handleAdded(iter)
        }, ctx, &addedIter)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), { refcon, iter in
            guard let refcon else { return }
            Unmanaged<PanelDiscovery>.fromOpaque(refcon).takeUnretainedValue().handleRemoved(iter)
        }, ctx, &removedIter)

        // Drain both iterators: arms the notifications and reports devices already present.
        handleAdded(addedIter)
        handleRemoved(removedIter)
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            resolve(service, attempt: 0)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        var any = false
        while case let service = IOIteratorNext(iter), service != 0 {
            IOObjectRelease(service)
            any = true
        }
        if any { onDisappear() }
    }

    /// Takes ownership of `service`.
    private func resolve(_ service: io_object_t, attempt: Int) {
        if let path = Self.calloutPath(service) {
            IOObjectRelease(service)
            onAppear(path)
            return
        }
        guard attempt + 1 < Self.resolveAttempts, notifyPort != nil else {
            IOObjectRelease(service)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveInterval) { [weak self] in
            guard let self else { IOObjectRelease(service); return }
            self.resolve(service, attempt: attempt + 1)
        }
    }

    static func calloutPath(_ service: io_object_t) -> String? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, "IOCalloutDevice" as CFString,
                                        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String
    }
}

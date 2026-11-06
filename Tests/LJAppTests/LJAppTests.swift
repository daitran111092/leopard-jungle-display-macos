import Testing
import LJCore
@testable import LJApp

@Test func statusLineConnected() {
    #expect(LJRuntime.statusLine(connected: true, fps: 59.6) == "Connected · 60 fps")
    #expect(LJRuntime.statusLine(connected: true, fps: 0) == "Connected · 0 fps")
}

@Test func statusLineDisconnected() {
    #expect(LJRuntime.statusLine(connected: false, fps: 60) == "Panel not found")
}

@Test func geometryWarningOnlyForUnexpectedPanels() {
    let ok = PanelInfo(width: 1920, height: 462, angle: 270, version: "3.1", model: "m", brightness: 80)
    #expect(PanelLink.geometryWarning(ok) == nil)
    var rotated = ok
    rotated.angle = 0
    #expect(PanelLink.geometryWarning(rotated)?.contains("angle 0") == true)
    var other = ok
    other.width = 1280
    #expect(PanelLink.geometryWarning(other)?.contains("1280x462") == true)
}

@Test func effectLogText() {
    #expect(LJRuntime.describe(.media(.seek(12.345))) == "media seek 12.3 s")
    #expect(LJRuntime.describe(.media(.toggle)) == "media toggle")
    #expect(LJRuntime.describe(.media(.next)) == "media next")
}

import Foundation

/// A port whose open blocks until released — models a handshake that hangs on a misbehaving panel/cable
/// (seen 2026-11-04: after a "connect failed: timeout" the app never attempted again).
private final class HangingOpens: @unchecked Sendable {
    let lock = NSLock()
    var opens = 0
    let gate = DispatchSemaphore(value: 0)
    func open() throws -> PortIO {
        lock.withLock { opens += 1 }
        gate.wait()                       // hangs until the test releases it
        throw PanelError.timeout
    }
    var count: Int { lock.withLock { opens } }
}

@MainActor @Test func hungConnectIsAbandonedAndRetried() async throws {
    let h = HangingOpens()
    let link = PanelLink(open: { _ in try h.open() }, connectTimeout: 0.2)
    link.appeared("/dev/fake")
    for _ in 0..<30 where h.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(h.count >= 2)                 // the first attempt hung; the watchdog gave up and tried again
    for _ in 0..<h.count + 4 { h.gate.signal() }
    link.disappeared()
}

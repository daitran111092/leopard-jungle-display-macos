import Testing
import Foundation
@testable import LJCore

private let infoJSON = #"{"cmd":"info","data":{"width":1920,"height":462,"angle":270,"version":"3.1","model":"D215-NOR-FL7707N-9.16inch-hor","brightness":80}}"#

private func replyFrame(_ json: String) -> Data {
    let body = Array(json.utf8)
    let len = body.count + 7
    var f: [UInt8] = [0x55, 0xAA, UInt8(len & 0xFF), UInt8(len >> 8), 0x06] + body
    let sum = f.reduce(0) { $0 + Int($1) }
    f += [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
    return Data(f)
}

struct FakeError: Error {}

/// Records writes; serves scripted read chunks; can block a matching write until released, or throw.
final class FakePort: PortIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    private var replies: [Data]
    private let clock: ManualClock?
    private var _throwOnWrite = false
    private var _throwOnRead = false
    private var _stallWrites: TimeInterval?
    private var _readCount = 0
    private let advanceClockOnEmptyRead: Bool
    private var blockWhen: (@Sendable (Data) -> Bool)?
    private(set) var closed = false
    let blocked = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)

    /// `replies` are returned one chunk per read. When empty, a read either "waits" its timeout on the manual
    /// `clock` (`advanceClockOnEmptyRead`, for handshake-timeout tests) or sleeps 10 ms of real time.
    init(replies: [Data], clock: ManualClock?, advanceClockOnEmptyRead: Bool = false) {
        self.replies = replies
        self.clock = clock
        self.advanceClockOnEmptyRead = advanceClockOnEmptyRead
    }

    static func withInfo(clock: ManualClock, then extra: [Data] = []) -> FakePort {
        let r = replyFrame(infoJSON)
        // Reply arrives in two chunks, as on the real device.
        return FakePort(replies: [r.prefix(20), r.dropFirst(20)].map { Data($0) } + extra, clock: clock)
    }

    var writes: [Data] { lock.withLock { _writes } }
    var throwOnWrite: Bool {
        get { lock.withLock { _throwOnWrite } }
        set { lock.withLock { _throwOnWrite = newValue } }
    }
    var throwOnRead: Bool {
        get { lock.withLock { _throwOnRead } }
        set { lock.withLock { _throwOnRead = newValue } }
    }
    /// Each write blocks this long (real time), then throws — what SerialPort does on a write timeout.
    var stallWrites: TimeInterval? {
        get { lock.withLock { _stallWrites } }
        set { lock.withLock { _stallWrites = newValue } }
    }
    var readCount: Int { lock.withLock { _readCount } }
    var pendingReplies: Int { lock.withLock { replies.count } }
    func block(when p: @escaping @Sendable (Data) -> Bool) { lock.withLock { blockWhen = p } }

    func write(_ d: Data) throws {
        if let stall = stallWrites {
            Thread.sleep(forTimeInterval: stall)
            throw FakeError()
        }
        let shouldBlock: Bool = try lock.withLock {
            if _throwOnWrite { throw FakeError() }
            _writes.append(d)
            let b = blockWhen?(d) ?? false
            if b { blockWhen = nil }
            return b
        }
        if shouldBlock {
            blocked.signal()
            gate.wait()
        }
    }

    func read(timeout: TimeInterval) throws -> Data {
        let next: Data? = try lock.withLock {
            if closed { throw FakeError() }
            if _throwOnRead { throw FakeError() }
            _readCount += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        if let next { return next }
        if advanceClockOnEmptyRead { clock?.advance(by: timeout) } else { Thread.sleep(forTimeInterval: 0.01) }
        return Data()
    }

    func close() { lock.withLock { closed = true } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private let live = controlFrame(.live)
private func img(_ d: Data) -> Data { imageFrame(d, wrapped: true) }

private func makePanel(_ ports: [FakePort], clock: ManualClock) -> Panel {
    let box = PortQueue(ports)
    return Panel(open: { try box.next() }, keepalive: 1.5, clock: clock.panelClock)
}

final class PortQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [FakePort]
    init(_ p: [FakePort]) { ports = p }
    func next() throws -> PortIO {
        try lock.withLock {
            guard !ports.isEmpty else { throw FakeError() }
            return ports.removeFirst()
        }
    }
}

@Test func connectSequence() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    let info = try panel.connect()
    #expect(port.writes == [clearSequence, controlFrame(.getInfo), live])
    #expect(info.height == 462)
    #expect(panel.info?.height == 462)
    #expect(panel.isConnected)
    panel.disconnect()
}

@Test func connectWaitsAfterClear() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    #expect(abs(clock.now - 0.3) < 1e-9)
    panel.disconnect()
}

@Test func keepaliveEvery1_5s() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    let before = port.writes.filter { $0 == live }.count
    clock.advance(by: 4.6)
    panel.waitForWriter()
    #expect(port.writes.filter { $0 == live }.count - before == 3)
    panel.disconnect()
    clock.advance(by: 10)
    panel.waitForWriter()
    #expect(port.writes.filter { $0 == live }.count - before == 3)
}

@Test func latestFrameWins() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    let a = Data([0xFF, 0xD8, 0xA]), b = Data([0xFF, 0xD8, 0xB]), c = Data([0xFF, 0xD8, 0xC])
    let wa = img(a)
    port.block { $0 == wa }
    panel.pushFrame(a)
    #expect(port.blocked.wait(timeout: .now() + 2) == .success)
    panel.pushFrame(b)
    panel.pushFrame(c)
    port.gate.signal()
    panel.waitForWriter()
    let images = port.writes.filter { $0 != live && $0 != clearSequence && $0 != controlFrame(.getInfo) }
    #expect(images == [img(a), img(c)])
    #expect(panel.stats.framesSent == 2)
    #expect(panel.stats.bytesSent == img(a).count + img(c).count)
    panel.disconnect()
}

@Test func controlNeverSplitsFrame() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    var frames: [Data] = []
    for i in 0..<20 {
        let f = Data([0xFF, 0xD8] + Array(repeating: UInt8(i), count: 5000))
        frames.append(f)
        panel.pushFrame(f)
        if i % 3 == 0 { panel.setBrightness(i * 5) }
        clock.advance(by: 0.4)
    }
    panel.waitForWriter()
    var allowed = Set([clearSequence, controlFrame(.getInfo), live])
    for p in 0...100 { allowed.insert(controlFrame(.brightness, [UInt8(p)])) }
    for f in frames { allowed.insert(img(f)) }
    #expect(port.writes.allSatisfy { allowed.contains($0) })
    // Brightness requests coalesce (newest wins), so the last one requested (i = 18 → 90) always lands.
    #expect(port.writes.contains(controlFrame(.brightness, [90])))
    panel.disconnect()
}

@Test func setBrightnessClamps() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    panel.setBrightness(150)
    panel.waitForWriter()
    panel.setBrightness(-5)
    panel.waitForWriter()
    let sent = port.writes.filter { $0.starts(with: [0x55, 0xAA]) && $0.count > 4 && $0[4] == Op.brightness.rawValue }
    #expect(sent == [controlFrame(.brightness, [100]), controlFrame(.brightness, [0])])
    panel.disconnect()
}

/// The firmware ignores 0x03 while live (verified on the device: no ack, getInfo unchanged), but acks and
/// applies it after CLEAR. So brightness leaves live mode, sets it, re-enters live and repaints the last frame.
@Test func setBrightnessLeavesLiveModeAndRepaintsLastFrame() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    let f = Data([0xFF, 0xD8, 7])
    panel.pushFrame(f)
    panel.waitForWriter()
    panel.setBrightness(40)
    panel.waitForWriter()
    #expect(Array(port.writes.suffix(4)) == [
        clearSequence, controlFrame(.brightness, [40]), controlFrame(.live), imageFrame(f, wrapped: true),
    ])
    panel.disconnect()
}

@Test func writeErrorDoesNotBlockCaller() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    let fired = Counter()
    panel.onDisconnect = { _ in fired.hit() }
    _ = try panel.connect()
    port.throwOnWrite = true
    let t0 = Date()
    panel.pushFrame(Data([0xFF, 0xD8, 1]))
    panel.pushFrame(Data([0xFF, 0xD8, 2]))
    #expect(Date().timeIntervalSince(t0) < 0.1)
    panel.waitForWriter()
    clock.advance(by: 3)
    panel.pushFrame(Data([0xFF, 0xD8, 3]))
    panel.waitForWriter()
    #expect(fired.value == 1)
    #expect(panel.isConnected == false)
    #expect(port.closed)
}

@Test func userDisconnectDoesNotFireOnDisconnect() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    let fired = Counter()
    panel.onDisconnect = { _ in fired.hit() }
    _ = try panel.connect()
    panel.disconnect()
    panel.waitForWriter()
    #expect(fired.value == 0)
    #expect(!panel.isConnected)
    #expect(port.closed)
}

@Test func reconnectsAfterPortError() throws {
    let clock = ManualClock()
    let p1 = FakePort.withInfo(clock: clock)
    let p2 = FakePort.withInfo(clock: clock)
    let panel = makePanel([p1, p2], clock: clock)
    _ = try panel.connect()
    p1.throwOnWrite = true
    panel.pushFrame(Data([0xFF, 0xD8, 1]))
    panel.waitForWriter()
    #expect(!panel.isConnected)
    let info = try panel.connect()
    #expect(info.width == 1920)
    #expect(panel.isConnected)
    let f = Data([0xFF, 0xD8, 2])
    panel.pushFrame(f)
    panel.waitForWriter()
    clock.advance(by: 1.6)
    panel.waitForWriter()
    #expect(p2.writes == [clearSequence, controlFrame(.getInfo), live, img(f), live])
    panel.disconnect()
}

@Test func getInfoTimeout() throws {
    let clock = ManualClock()
    let port = FakePort(replies: [], clock: clock, advanceClockOnEmptyRead: true)
    let panel = makePanel([port], clock: clock)
    #expect(throws: PanelError.timeout) { try panel.connect() }
    #expect(clock.now >= 3.3 - 1e-9)
    #expect(clock.now < 4.0)
    #expect(!panel.isConnected)
    #expect(port.closed)
}

@Test func getInfoResyncsPastJunk() throws {
    let clock = ManualClock()
    let port = FakePort(replies: [Data([0x00, 0x13, 0x55]), replyFrame(infoJSON)], clock: clock)
    let panel = makePanel([port], clock: clock)
    let info = try panel.connect()
    #expect(info.version == "3.1")
    panel.disconnect()
}

@Test func neverSendsForbiddenOpcodes() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    for i in 0..<10 {
        panel.pushFrame(Data([0xFF, 0xD8, UInt8(i)]))
        panel.setBrightness(i * 10)
        clock.advance(by: 0.7)
        panel.waitForWriter()
    }
    panel.waitForWriter()
    panel.disconnect()
    let forbidden: Set<UInt8> = [0x01, 0x0C, 0x20, 0x23]
    let bad = port.writes.filter { $0.count >= 5 && $0[0] == 0x55 && $0[1] == 0xAA && forbidden.contains($0[4]) }
    #expect(bad.isEmpty)
    #expect(port.writes.count > 20)
}

/// Polls `cond` for up to `seconds` of real time.
private func eventually(_ seconds: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return cond()
}

private let liveAck = Data([0x55, 0xAA, 0x08, 0x00, 0x11, 0x00, 0x18, 0x01])

@Test func drainsInputAfterConnect() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock, then: [liveAck, liveAck, liveAck])
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    #expect(eventually { port.pendingReplies == 0 })
    #expect(eventually { port.readCount >= 2 + 3 + 1 })  // handshake chunks + acks + keeps polling
    #expect(panel.isConnected)
    panel.disconnect()
    Thread.sleep(forTimeInterval: 0.05)
    let after = port.readCount
    Thread.sleep(forTimeInterval: 0.3)
    #expect(port.readCount == after)  // drain stops with the session
}

@Test func readErrorDisconnectsOnce() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    let fired = Counter()
    panel.onDisconnect = { _ in fired.hit() }
    _ = try panel.connect()
    port.throwOnRead = true
    #expect(eventually { fired.value == 1 })
    #expect(!panel.isConnected)
    #expect(port.closed)
    Thread.sleep(forTimeInterval: 0.1)
    #expect(fired.value == 1)
}

@Test func writeTimeoutDisconnects() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    let fired = Counter()
    panel.onDisconnect = { _ in fired.hit() }
    _ = try panel.connect()
    port.stallWrites = 0.2
    let t0 = Date()
    panel.pushFrame(Data([0xFF, 0xD8, 1]))
    panel.setBrightness(50)
    #expect(Date().timeIntervalSince(t0) < 0.1)
    panel.waitForWriter()
    #expect(fired.value == 1)
    #expect(!panel.isConnected)
    #expect(port.closed)
}

@Test func callersNeverBlockWhileWriteHeld() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    let a = Data([0xFF, 0xD8, 0xA])
    let wa = img(a)
    port.block { $0 == wa }
    panel.pushFrame(a)
    #expect(port.blocked.wait(timeout: .now() + 2) == .success)
    let t0 = Date()
    for i in 0..<50 { panel.pushFrame(Data([0xFF, 0xD8, UInt8(i)])); panel.setBrightness(i) }
    clock.advance(by: 3)  // keepalives enqueue while the write is held
    #expect(Date().timeIntervalSince(t0) < 0.5)
    port.gate.signal()
    panel.waitForWriter()
    #expect(port.writes.last == img(Data([0xFF, 0xD8, 49])))
    panel.disconnect()
}

@Test func disconnectSendingClearWritesClearLast() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    panel.pushFrame(Data([0xFF, 0xD8, 0x1]))
    #expect(panel.disconnect(sendingClear: true))
    #expect(port.writes.last == clearSequence)
    #expect(port.closed)
    #expect(!panel.isConnected)
    // Nothing more is written after the session ends.
    let n = port.writes.count
    clock.advance(by: 5)
    panel.waitForWriter()
    #expect(port.writes.count == n)
}

@Test func disconnectSendingClearWhenDisconnectedIsNoop() {
    let clock = ManualClock()
    let panel = makePanel([], clock: clock)
    #expect(!panel.disconnect(sendingClear: true))
}

@Test func disconnectSendingClearReportsWriteFailure() throws {
    let clock = ManualClock()
    let port = FakePort.withInfo(clock: clock)
    let panel = makePanel([port], clock: clock)
    _ = try panel.connect()
    port.throwOnWrite = true
    #expect(!panel.disconnect(sendingClear: true))
    #expect(port.closed)
}

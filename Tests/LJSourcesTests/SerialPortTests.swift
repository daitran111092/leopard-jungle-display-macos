import Testing
import Foundation
import Darwin
@testable import LJSources

/// A connected AF_UNIX stream pair: `port` wraps one end, `peer` is the raw other end.
private func pair(writeTimeout: TimeInterval) -> (port: SerialPort, peer: Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (SerialPort(adopting: fds[0], writeTimeout: writeTimeout), fds[1])
}

@Test func writeTimesOutWhenPeerStopsReading() {
    let (port, peer) = pair(writeTimeout: 0.2)
    defer { port.close(); close(peer) }
    let big = Data(count: 8 << 20)  // far beyond the socket buffer; nobody reads
    let t0 = Date()
    #expect {
        try port.write(big)
    } throws: { ($0 as? SerialPortError)?.code == ETIMEDOUT }
    let dt = Date().timeIntervalSince(t0)
    #expect(dt >= 0.15 && dt < 1.5)
}

@Test func writeWaitsForRoomWithoutSpinning() throws {
    let (port, peer) = pair(writeTimeout: 2)
    defer { port.close(); close(peer) }
    let total = 4 << 20
    let got = Counter()
    let reader = Thread {
        var buf = [UInt8](repeating: 0, count: 65536)
        while got.value < total {
            let n = read(peer, &buf, buf.count)
            if n <= 0 { break }
            got.add(n)
        }
    }
    reader.start()
    let cpu0 = clock()
    try port.write(Data(count: total))
    let cpu = Double(clock() - cpu0) / Double(CLOCKS_PER_SEC)
    let deadline = Date().addingTimeInterval(2)
    while got.value < total && Date() < deadline { usleep(1000) }
    #expect(got.value == total)
    #expect(cpu < 1.0)
}

@Test func readReturnsDataOrEmptyOnTimeout() throws {
    let (port, peer) = pair(writeTimeout: 1)
    defer { port.close(); close(peer) }
    let t0 = Date()
    #expect(try port.read(timeout: 0.1).isEmpty)
    #expect(Date().timeIntervalSince(t0) >= 0.09)
    let ack: [UInt8] = [0x55, 0xAA, 0x08, 0x00, 0x11, 0x00, 0x18, 0x01]
    _ = ack.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
    #expect(try port.read(timeout: 1) == Data(ack))
}

@Test func readThrowsOnHangup() {
    let (port, peer) = pair(writeTimeout: 1)
    defer { port.close() }
    close(peer)
    #expect(throws: SerialPortError.self) { try port.read(timeout: 1) }
}

@Test func closedPortThrows() {
    let (port, peer) = pair(writeTimeout: 1)
    defer { close(peer) }
    port.close()
    #expect(throws: SerialPortError.self) { try port.write(Data([1])) }
    #expect(throws: SerialPortError.self) { try port.read(timeout: 0.01) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) { lock.withLock { n += k } }
    var value: Int { lock.withLock { n } }
}

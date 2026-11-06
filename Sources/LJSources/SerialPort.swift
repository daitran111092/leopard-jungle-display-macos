import Foundation
import Darwin
import LJCore

public struct SerialPortError: Error, CustomStringConvertible, Sendable {
    public let op: String
    public let code: Int32
    public var description: String { "\(op): \(String(cString: strerror(code))) (errno \(code))" }
}

/// POSIX CDC-ACM serial port: exclusive, raw, DTR asserted. The fd stays O_NONBLOCK; writes wait with
/// `poll(POLLOUT)` and throw after `writeTimeout`, reads wait with `poll(POLLIN)`.
///
/// Every syscall on the fd runs while `lock` is held after checking the fd is still open, so a concurrent
/// `close()` can never cause a write or read on a recycled fd number. Waiting (`poll`) happens outside the lock.
public final class SerialPort: PortIO, @unchecked Sendable {
    /// Per-`write` deadline. A ~120 KB frame takes ~15 ms at the measured 8.5 MB/s.
    public static let defaultWriteTimeout: TimeInterval = 2

    private let lock = NSLock()
    private var fd: Int32
    private let writeTimeout: TimeInterval

    public init(path: String, writeTimeout: TimeInterval = SerialPort.defaultWriteTimeout) throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError(op: "open \(path)", code: errno) }
        func fail(_ op: String) -> SerialPortError {
            let e = SerialPortError(op: op, code: errno)
            Darwin.close(fd)
            return e
        }
        guard ioctl(fd, TIOCEXCL) == 0 else { throw fail("TIOCEXCL") }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw fail("tcgetattr") }
        cfmakeraw(&t)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw fail("tcsetattr") }
        var dtr = TIOCM_DTR
        guard ioctl(fd, TIOCMBIS, &dtr) == 0 else { throw fail("TIOCMBIS DTR") }
        self.fd = fd
        self.writeTimeout = writeTimeout
    }

    /// Adopts an already-open fd (tests use a socketpair). Sets O_NONBLOCK.
    init(adopting fd: Int32, writeTimeout: TimeInterval) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        self.writeTimeout = writeTimeout
    }

    deinit { close() }

    private static let closedError = SerialPortError(op: "port closed", code: EBADF)

    /// Runs `body(fd)` under the lock if the port is still open; returns its result and the errno right after it.
    private func withFD(_ body: (Int32) -> Int) throws -> (Int, Int32) {
        try lock.withLock {
            guard fd >= 0 else { throw Self.closedError }
            let r = body(fd)
            return (r, errno)
        }
    }

    private func currentFD() throws -> Int32 {
        let f = lock.withLock { fd }
        guard f >= 0 else { throw Self.closedError }
        return f
    }

    /// Waits for `events` on the fd. Returns false on timeout; throws on error/hangup.
    private func wait(_ events: Int32, timeout: TimeInterval, op: String) throws -> Bool {
        var pfd = pollfd(fd: try currentFD(), events: Int16(events), revents: 0)
        let ms = Int32((max(0, min(timeout, 60)) * 1000).rounded(.up))
        let r = poll(&pfd, 1, ms)
        if r < 0 {
            if errno == EINTR { return true }   // caller retries the syscall
            throw SerialPortError(op: "\(op) poll", code: errno)
        }
        if r == 0 { return false }
        if pfd.revents & Int16(events) == 0 {   // POLLHUP / POLLERR / POLLNVAL without data
            throw SerialPortError(op: "\(op) poll revents \(pfd.revents)", code: ENXIO)
        }
        return true
    }

    public func write(_ d: Data) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + writeTimeout
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.baseAddress else { return }
            var off = 0
            while off < p.count {
                let (n, err) = try withFD { Darwin.write($0, base + off, p.count - off) }
                if n > 0 { off += n; continue }
                if n < 0 && err == EINTR { continue }
                if n < 0 && err != EAGAIN { throw SerialPortError(op: "write", code: err) }
                // Output buffer full: wait for room (never spin).
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, try wait(POLLOUT, timeout: remaining, op: "write") else {
                    throw SerialPortError(op: "write timeout after \(writeTimeout) s (\(off)/\(p.count) bytes)",
                                          code: ETIMEDOUT)
                }
            }
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard try wait(POLLIN, timeout: timeout, op: "read") else { return Data() }
        var buf = [UInt8](repeating: 0, count: 4096)
        let (n, err) = try buf.withUnsafeMutableBytes { b in
            try withFD { Darwin.read($0, b.baseAddress, b.count) }
        }
        if n < 0 {
            if err == EAGAIN || err == EINTR { return Data() }
            throw SerialPortError(op: "read", code: err)
        }
        if n == 0 { throw SerialPortError(op: "read EOF", code: ENXIO) }
        return Data(buf[0..<n])
    }

    /// Discards pending output and caps the tty drain wait first, so `close` can't block on a panel that
    /// stopped reading (a tty close otherwise waits for unsent output to drain).
    public func close() {
        lock.withLock {
            if fd >= 0 {
                tcflush(fd, TCIOFLUSH)
                var drainWait: Int32 = 1
                _ = ioctl(fd, TIOCSDRAINWAIT, &drainWait)
                Darwin.close(fd)
            }
            fd = -1
        }
    }
}

import Foundation

public enum PanelError: Error, Equatable, Sendable {
    case badMagic
    case notJSON(code: String)
    case timeout
}

/// The only opcodes this app may ever send to the panel.
public enum Op: UInt8, Sendable {
    case getInfo = 0x06
    case brightness = 0x03
    case live = 0x11
}

private func sum16(_ bytes: [UInt8]) -> [UInt8] {
    let s = bytes.reduce(0) { $0 &+ Int($1) }
    return [UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF)]
}

/// `55 AA | len u16 LE (= payload + 7) | key | payload | sum16 LE`
public func controlFrame(_ op: Op, _ payload: [UInt8] = []) -> Data {
    let len = payload.count + 7
    var f: [UInt8] = [0x55, 0xAA, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), op.rawValue]
    f += payload
    f += sum16(f)
    return Data(f)
}

/// Wrapped (version > 2.8): `len u32 LE | jpeg | sum16 LE` (sum over len bytes + jpeg). Bare: the JPEG itself.
public func imageFrame(_ jpeg: Data, wrapped: Bool) -> Data {
    guard wrapped else { return jpeg }
    let n = UInt32(jpeg.count)
    var f: [UInt8] = [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    f += jpeg
    f += sum16(f)
    return Data(f)
}

public let clearSequence = Data([0xFF, 0xD9, 0xFF, 0xD9, 0, 0, 0, 0])

public struct PanelInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var angle: Int
    public var version: String
    public var model: String
    public var brightness: Int

    public init(width: Int, height: Int, angle: Int, version: String, model: String, brightness: Int) {
        self.width = width; self.height = height; self.angle = angle
        self.version = version; self.model = model; self.brightness = brightness
    }

    /// Firmware newer than 2.8 expects the length-prefixed image frame. Unparseable → false.
    public var usesLengthHeader: Bool { (Double(version) ?? 0) > 2.8 }
}

public enum ReplyParse {
    case incomplete
    case reply(json: [String: Any], consumed: Int)
}

/// Parses one reply frame from the front of `buf`; JSON lives at bytes `[5 ..< len-2]`.
public func parseReply(_ buf: Data) throws -> ReplyParse {
    let b = [UInt8](buf)
    if b.count >= 1 && b[0] != 0x55 { throw PanelError.badMagic }
    if b.count >= 2 && b[1] != 0xAA { throw PanelError.badMagic }
    guard b.count >= 4 else { return .incomplete }
    let len = Int(b[2]) | (Int(b[3]) << 8)
    guard len >= 7 else { throw PanelError.notJSON(code: "len=\(len)") }
    guard b.count >= len else { return .incomplete }
    let body = Data(b[5..<(len - 2)])
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw PanelError.notJSON(code: String(decoding: body.prefix(64), as: UTF8.self))
    }
    return .reply(json: obj, consumed: len)
}

public func parsePanelInfo(_ json: [String: Any]) -> PanelInfo? {
    let d = (json["data"] as? [String: Any]) ?? json
    guard let w = d["width"] as? Int, let h = d["height"] as? Int else { return nil }
    return PanelInfo(
        width: w, height: h,
        angle: d["angle"] as? Int ?? 0,
        version: d["version"] as? String ?? "",
        model: d["model"] as? String ?? "",
        brightness: d["brightness"] as? Int ?? 0)
}

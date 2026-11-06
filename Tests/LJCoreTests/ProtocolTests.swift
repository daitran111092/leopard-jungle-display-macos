import Testing
import Foundation
@testable import LJCore

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func replyFrame(json: String, trailing: [UInt8] = []) -> Data {
    let body = Array(json.utf8)
    let len = body.count + 7
    var f: [UInt8] = [0x55, 0xAA, UInt8(len & 0xFF), UInt8(len >> 8), 0x06] + body
    let sum = f.reduce(0) { $0 + Int($1) }
    f += [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
    return Data(f + trailing)
}

private let infoJSON = #"{"cmd":"info","data":{"width":1920,"height":462,"angle":270,"version":"3.1","model":"D215-NOR-FL7707N-9.16inch-hor","brightness":80}}"#

@Test func getInfoFrame() { #expect(controlFrame(.getInfo).hex == "55aa0700060c01") }
@Test func brightnessFrame() { #expect(controlFrame(.brightness, [80]).hex == "55aa080003505a01") }
@Test func wrappedImage() { #expect(imageFrame(Data([1, 2, 3]), wrapped: true).hex == "030000000102030900") }
@Test func bareImage() { #expect(imageFrame(Data([1, 2]), wrapped: false) == Data([1, 2])) }

@Test func clearSequenceBytes() { #expect(clearSequence.hex == "ffd9ffd900000000") }

@Test func parsesRealInfoReply() throws {
    let frame = replyFrame(json: infoJSON)
    let buf = frame + Data([1, 2, 3])
    guard case let .reply(json, consumed) = try parseReply(buf) else {
        Issue.record("expected reply"); return
    }
    #expect(consumed == frame.count)
    let info = try #require(parsePanelInfo(json))
    #expect(info.width == 1920)
    #expect(info.height == 462)
    #expect(info.angle == 270)
    #expect(info.brightness == 80)
    #expect(info.model == "D215-NOR-FL7707N-9.16inch-hor")
    #expect(info.usesLengthHeader)
}

@Test func incompleteReply() throws {
    let frame = replyFrame(json: infoJSON)
    guard case .incomplete = try parseReply(frame.prefix(10)) else {
        Issue.record("expected incomplete"); return
    }
}

@Test func badMagicThrows() {
    #expect(throws: PanelError.badMagic) { try parseReply(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])) }
}

@Test func nonJSONThrows() {
    let f = replyFrame(json: "not json")
    #expect(throws: PanelError.self) { try parseReply(f) }
}

@Test func versionGate() {
    func info(_ v: String) -> PanelInfo {
        PanelInfo(width: 1, height: 1, angle: 0, version: v, model: "", brightness: 0)
    }
    #expect(info("3.1").usesLengthHeader)
    #expect(!info("2.8").usesLengthHeader)
    #expect(!info("Ver1.0").usesLengthHeader)
}

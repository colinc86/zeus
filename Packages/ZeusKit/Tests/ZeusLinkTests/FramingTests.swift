import Foundation
import Testing
import ZeusProtocol
@testable import ZeusLink

@Test func partialAndMultipleLines() throws {
    let message = WireMessage.error(.init(message: "Hello"))
    let data = try NDJSONFramer.encode(message)
    var framer = NDJSONFramer()
    #expect(try framer.append(data.prefix(4)).isEmpty)
    #expect(try framer.append(data.dropFirst(4)) == [message])
    #expect(try framer.append(data + data + data) == [message, message, message])
    try framer.finish()
}

@Test func utf8SplitAcrossEveryByte() throws {
    let message = WireMessage.push(.init(deliveryID: "d_12345678", content: "Zeus ⚡ café 🦉\nNext line"))
    let data = try NDJSONFramer.encode(message)
    var framer = NDJSONFramer()
    var decoded: [WireMessage] = []
    for byte in data { decoded += try framer.append(Data([byte])) }
    #expect(decoded == [message])
    #expect(data.filter { $0 == 10 }.count == 1)
    try framer.finish()
}

@Test func framingRejectsMalformedAndOversizedInput() throws {
    var truncated = NDJSONFramer()
    #expect(try truncated.append(Data(#"{"type":"error""#.utf8)).isEmpty)
    #expect(throws: BridgeLinkError.truncatedMessage) { try truncated.finish() }
    var invalidUTF8 = NDJSONFramer()
    #expect(throws: BridgeLinkError.invalidUTF8) { try invalidUTF8.append(Data([0xff, 10])) }
    var invalidJSON = NDJSONFramer()
    #expect(throws: (any Error).self) { try invalidJSON.append(Data("not json\n".utf8)) }
    var oversized = NDJSONFramer(maximumFrameBytes: 10)
    #expect(throws: BridgeLinkError.messageTooLarge) { try oversized.append(Data(repeating: 65, count: 11)) }
    let message = WireMessage.error(.init(message: "x"))
    let frame = try NDJSONFramer.encode(message)
    var bounded = NDJSONFramer(maximumFrameBytes: frame.count - 1)
    #expect(try bounded.append(frame + frame) == [message, message])
    var crlf = NDJSONFramer()
    #expect(try crlf.append(frame.dropLast() + Data([13, 10])) == [message])
}

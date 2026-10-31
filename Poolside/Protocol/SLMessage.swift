import Foundation

/// ScreenLogic wire format.
/// Every message is an 8-byte little-endian header (uint16 sender, uint16 message id,
/// uint32 payload length) followed by the payload. Strings and byte arrays carry an
/// int32 length and are zero-padded to a 4-byte boundary.
struct SLMessage {
    var senderId: UInt16 = 0
    var messageId: UInt16
    var payload: Data

    static let headerSize = 8

    init(id: UInt16, payload: Data = Data(), senderId: UInt16 = 0) {
        self.messageId = id
        self.payload = payload
        self.senderId = senderId
    }

    func encoded() -> Data {
        var w = ByteWriter()
        w.uint16(senderId)
        w.uint16(messageId)
        w.uint32(UInt32(payload.count))
        w.bytes(payload)
        return w.data
    }

    /// Pulls one complete message off the front of `buffer`, or returns nil if more bytes are needed.
    static func take(from buffer: inout Data) -> SLMessage? {
        guard buffer.count >= headerSize else { return nil }
        var r = ByteReader(buffer)
        let sender = (try? r.uint16()) ?? 0
        let id = (try? r.uint16()) ?? 0
        let length = Int((try? r.uint32()) ?? 0)
        guard buffer.count >= headerSize + length else { return nil }
        let start = buffer.startIndex + headerSize
        let body = Data(buffer[start..<(start + length)])
        buffer = Data(buffer[(start + length)...])
        return SLMessage(id: id, payload: body, senderId: sender)
    }

    var reader: ByteReader { ByteReader(payload) }
}

enum SLWireError: Error {
    case truncated
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func uint8(_ v: UInt8) { data.append(v) }

    mutating func uint16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    mutating func uint32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func int32(_ v: Int32) { uint32(UInt32(bitPattern: v)) }
    mutating func int32(_ v: Int) { int32(Int32(truncatingIfNeeded: v)) }

    mutating func bytes(_ d: Data) { data.append(d) }

    mutating func pad(_ length: Int) {
        let slack = (4 - length % 4) % 4
        if slack > 0 { data.append(Data(count: slack)) }
    }

    mutating func string(_ s: String) {
        let utf8 = Data(s.utf8)
        int32(utf8.count)
        bytes(utf8)
        pad(utf8.count)
    }

    mutating func array(_ d: Data) {
        int32(d.count)
        bytes(d)
        pad(d.count)
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { self.bytes = Array(data) }

    var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw SLWireError.truncated }
        let slice = Array(bytes[offset..<(offset + n)])
        offset += n
        return slice
    }

    mutating func skip(_ n: Int) throws { _ = try take(n) }

    mutating func uint8() throws -> UInt8 { try take(1)[0] }

    mutating func uint16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    mutating func uint32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func int32() throws -> Int { Int(Int32(bitPattern: try uint32())) }

    mutating func string() throws -> String {
        let length = try int32()
        let raw = try take(length)
        try skip((4 - length % 4) % 4)
        return String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}

import Foundation

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

enum ProtoError: Error {
    case unexpectedEnd
    case invalidVarint
    case invalidWireType(UInt8)
    case fieldLengthOverflow
}

struct ProtoWriter {
    private(set) var data = Data()

    mutating func writeVarint(field: Int, value: UInt64) {
        appendTag(field: field, wire: .varint)
        appendVarint(value)
    }

    mutating func writeBool(field: Int, value: Bool) {
        writeVarint(field: field, value: value ? 1 : 0)
    }

    mutating func writeEnum<E: RawRepresentable>(field: Int, value: E) where E.RawValue == Int {
        writeVarint(field: field, value: UInt64(value.rawValue))
    }

    mutating func writeFloat(field: Int, value: Float) {
        appendTag(field: field, wire: .fixed32)
        let bits = value.bitPattern
        for i in 0..<4 { data.append(UInt8((bits >> (i * 8)) & 0xFF)) }
    }

    mutating func writeLengthDelimited(field: Int, bytes: Data) {
        appendTag(field: field, wire: .lengthDelimited)
        appendVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeMessage(field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        writeLengthDelimited(field: field, bytes: inner.data)
    }

    private mutating func appendTag(field: Int, wire: ProtoWireType) {
        appendVarint(UInt64(field) << 3 | UInt64(wire.rawValue))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

struct ProtoReader {
    /// Optional hook invoked when `skip` is called with an unknown
    /// field. Used for diagnostic logging in DEBUG builds and for
    /// verifying parser behavior in tests. Nil in production (no-op).
    /// Per ARCHITECTURE_REVIEW L9-5: lets us notice when firmware
    /// emits new fields we don't parse.
    nonisolated(unsafe) static var unknownFieldHandler: ((_ field: Int, _ wire: ProtoWireType, _ byteCount: Int) -> Void)?

    private let bytes: Data
    private var index: Int

    init(_ data: Data) {
        self.bytes = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }

    mutating func readTag() throws -> (field: Int, wire: ProtoWireType) {
        let tag = try readVarint()
        guard let wire = ProtoWireType(rawValue: UInt8(tag & 0x7)) else {
            throw ProtoError.invalidWireType(UInt8(tag & 0x7))
        }
        return (Int(tag >> 3), wire)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.endIndex else { throw ProtoError.unexpectedEnd }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { throw ProtoError.invalidVarint }
        }
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    mutating func readFloat() throws -> Float {
        guard index + 4 <= bytes.endIndex else { throw ProtoError.unexpectedEnd }
        var bits: UInt32 = 0
        for i in 0..<4 {
            bits |= UInt32(bytes[index + i]) << (i * 8)
        }
        index += 4
        return Float(bitPattern: bits)
    }

    mutating func readLengthDelimited() throws -> Data {
        let len = Int(try readVarint())
        guard len >= 0, index + len <= bytes.endIndex else { throw ProtoError.fieldLengthOverflow }
        let slice = bytes.subdata(in: index..<(index + len))
        index += len
        return slice
    }

    mutating func skip(wire: ProtoWireType) throws {
        try skip(field: nil, wire: wire)
    }

    /// Skip a field, optionally invoking `unknownFieldHandler` if a field
    /// number is supplied. Parsers should always call this overload so
    /// the diagnostic hook can fire.
    ///
    /// `byteCount` semantics for the handler:
    /// - `.varint` — bytes consumed by the varint encoding (1–10).
    /// - `.fixed32` / `.fixed64` — 4 or 8 (the fixed payload size).
    /// - `.lengthDelimited` — the payload size (NOT including the
    ///   varint length prefix), which is the most useful diagnostic.
    mutating func skip(field: Int?, wire: ProtoWireType) throws {
        let payloadBytes: Int
        switch wire {
        case .varint:
            let pre = index
            _ = try readVarint()
            payloadBytes = index - pre
        case .fixed64:
            guard index + 8 <= bytes.endIndex else { throw ProtoError.unexpectedEnd }
            index += 8
            payloadBytes = 8
        case .lengthDelimited:
            payloadBytes = try readLengthDelimited().count
        case .fixed32:
            guard index + 4 <= bytes.endIndex else { throw ProtoError.unexpectedEnd }
            index += 4
            payloadBytes = 4
        }
        if let field, let handler = Self.unknownFieldHandler {
            handler(field, wire, payloadBytes)
        }
    }
}

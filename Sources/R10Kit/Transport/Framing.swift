import Foundation

enum R10Opcode {
    static let protoRequest: [UInt8] = [0xB3, 0x13]
    static let protoResponse: [UInt8] = [0xB4, 0x13]
    static let ack: [UInt8] = [0x88, 0x13]
    static let deviceInfo: [UInt8] = [0xA0, 0x13]
    static let config: [UInt8] = [0xBA, 0x13]
}

enum FramingError: Error {
    case crcMismatch
    case cobsDecodeFailed
    case frameTooShort
    case unknownOpcode([UInt8])
}

enum Framing {
    private static let crcTable: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var v: UInt16 = 0
            var x: UInt16 = UInt16(i)
            for _ in 0..<8 {
                if ((v ^ x) & 1) != 0 { v = (v >> 1) ^ 0xA001 } else { v >>= 1 }
                x >>= 1
            }
            t[i] = v
        }
        return t
    }()

    static func crc16(_ input: Data) -> UInt16 {
        var crc: UInt16 = 0
        for b in input {
            let idx = Int(UInt8(crc & 0xFF) ^ b)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc
    }

    static func cobsEncode(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        var out = Data()
        out.reserveCapacity(input.count + (input.count / 254) + 2)
        var blockStart = out.count
        out.append(0)
        var blockLen: UInt8 = 1

        for byte in input {
            if byte != 0 {
                out.append(byte)
                blockLen &+= 1
                if blockLen == 0xFF {
                    out[blockStart] = 0xFF
                    blockStart = out.count
                    out.append(0)
                    blockLen = 1
                }
            } else {
                out[blockStart] = blockLen
                blockStart = out.count
                out.append(0)
                blockLen = 1
            }
        }
        out[blockStart] = blockLen
        return out
    }

    static func cobsDecode(_ input: Data) -> Data? {
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let code = input[i]
            if code == 0 { return nil }
            let blockEnd = i + Int(code)
            if blockEnd > input.endIndex { return nil }
            var j = i + 1
            while j < blockEnd {
                let b = input[j]
                if b == 0 { return nil }
                out.append(b)
                j += 1
            }
            i = blockEnd
            if code != 0xFF, i < input.endIndex {
                out.append(0)
            }
        }
        return out
    }

    /// Wraps a raw payload (e.g. B313+counter+...+proto) in length prefix + CRC,
    /// COBS-encodes the result, and adds 0x00 sentinels at both ends.
    /// Output is the on-wire byte stream prior to BLE chunking.
    static func encodeOuter(_ payload: Data) -> Data {
        precondition(payload.count <= Int(UInt16.max) - 4, "payload exceeds 2-byte length field")
        let length = UInt16(2 + payload.count + 2)
        var inner = Data()
        inner.reserveCapacity(2 + payload.count + 2)
        inner.append(UInt8(length & 0xFF))
        inner.append(UInt8((length >> 8) & 0xFF))
        inner.append(payload)
        let crc = crc16(inner)
        inner.append(UInt8(crc & 0xFF))
        inner.append(UInt8((crc >> 8) & 0xFF))

        var out = Data()
        out.append(0x00)
        out.append(cobsEncode(inner))
        out.append(0x00)
        return out
    }

    /// Reverse of encodeOuter for a single complete inbound frame buffer
    /// (with 0x00 sentinels already stripped). Validates CRC and returns the
    /// raw payload (length prefix + CRC suffix removed).
    static func decodeOuter(_ cobsBytes: Data) throws -> Data {
        guard let decoded = cobsDecode(cobsBytes) else { throw FramingError.cobsDecodeFailed }
        guard decoded.count >= 4 else { throw FramingError.frameTooShort }
        let bodyEnd = decoded.endIndex - 2
        let body = decoded.subdata(in: decoded.startIndex..<bodyEnd)
        let want = crc16(body)
        let lo = decoded[bodyEnd]
        let hi = decoded[bodyEnd + 1]
        let got = UInt16(lo) | (UInt16(hi) << 8)
        guard want == got else { throw FramingError.crcMismatch }
        return body.subdata(in: (body.startIndex + 2)..<body.endIndex)
    }

    /// Splits the encoded outer frame into BLE writes of up to 19 bytes,
    /// prepending the session header byte to each chunk.
    static func chunk(_ encoded: Data, header: UInt8) -> [Data] {
        var chunks: [Data] = []
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let end = min(i + 19, encoded.endIndex)
            var chunk = Data()
            chunk.reserveCapacity(1 + (end - i))
            chunk.append(header)
            chunk.append(encoded.subdata(in: i..<end))
            chunks.append(chunk)
            i = end
        }
        return chunks
    }

    /// Build a B313 proto request payload (suitable for encodeOuter).
    /// Layout: [B3 13][counter LE 4][0x00 0x00][len LE 4][len LE 4][protoBytes]
    static func protoRequestPayload(counter: UInt32, protoBytes: Data) -> Data {
        var p = Data()
        p.reserveCapacity(16 + protoBytes.count)
        p.append(contentsOf: R10Opcode.protoRequest)
        for i in 0..<4 { p.append(UInt8((counter >> (i * 8)) & 0xFF)) }
        p.append(0x00); p.append(0x00)
        let len = UInt32(protoBytes.count)
        for i in 0..<4 { p.append(UInt8((len >> (i * 8)) & 0xFF)) }
        for i in 0..<4 { p.append(UInt8((len >> (i * 8)) & 0xFF)) }
        p.append(protoBytes)
        return p
    }

    /// Build an ack for a received inbound payload (post decodeOuter).
    /// Mirrors mholow's AcknowledgeMessage: 8813 + first 2 bytes of inbound + ackBody,
    /// where ackBody = [0x00] (+ counter LE 2 + 7 zero bytes if inbound is a B413/B313 proto).
    static func ackPayload(for inbound: Data) -> Data {
        guard inbound.count >= 2 else { return Data() }
        let opcode: [UInt8] = [inbound[inbound.startIndex], inbound[inbound.startIndex + 1]]
        var p = Data()
        p.append(contentsOf: R10Opcode.ack)
        p.append(opcode[0]); p.append(opcode[1])
        p.append(0x00)
        if (opcode == R10Opcode.protoResponse || opcode == R10Opcode.protoRequest), inbound.count >= 4 {
            p.append(inbound[inbound.startIndex + 2])
            p.append(inbound[inbound.startIndex + 3])
            p.append(contentsOf: [UInt8](repeating: 0, count: 7))
        }
        return p
    }

    static let handshakeRequest: Data = Data([
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00
    ])

    static let handshakeResponsePrefix: Data = Data([
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00
    ])
}

/// Reassembles inbound BLE chunks into complete COBS-decoded payloads.
/// Each BLE chunk begins with a 1-byte session header that is stripped here.
/// A leading 0x00 in the remaining bytes resets the assembly buffer; a trailing
/// 0x00 marks frame completion.
struct FrameAssembler {
    enum Output {
        case handshake(Data)   // remaining bytes (after header strip) when header byte == 0
        case payload(Data)     // post-decodeOuter payload (length prefix + CRC stripped, validated)
    }

    /// Hard cap on assembly buffer. Any plausible R10 frame is well under 1KB; if
    /// we exceed this we've lost frame sync and should drop the buffer rather than
    /// grow without bound. The R10 will resend on missing acks.
    static let maxBufferBytes = 4096

    private var buffer = Data()
    private(set) var handshakeComplete = false

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        handshakeComplete = false
    }

    mutating func markHandshakeComplete() { handshakeComplete = true }

    mutating func feed(_ chunk: Data) throws -> [Output] {
        guard !chunk.isEmpty else { return [] }
        let header = chunk[chunk.startIndex]
        let body = chunk.subdata(in: (chunk.startIndex + 1)..<chunk.endIndex)

        if header == 0 || !handshakeComplete {
            return [.handshake(body)]
        }

        // Walk the chunk byte-by-byte. Each 0x00 is a COBS sentinel —
        // a frame boundary. A single BLE chunk can legitimately contain
        // the tail of frame A + boundary + start of frame B (or even a
        // complete frame mid-chunk), and we must NOT smash these together
        // into one buffer. Doing so was the cause of the CRC mismatches
        // we observed when a state alert arrived alongside the tail of
        // a B413 response.
        var outputs: [Output] = []
        for byte in body {
            if byte == 0 {
                if !buffer.isEmpty {
                    let cobsBytes = buffer
                    buffer.removeAll(keepingCapacity: true)
                    do {
                        let payload = try Framing.decodeOuter(cobsBytes)
                        outputs.append(.payload(payload))
                    } catch {
                        // Drop this malformed frame, continue parsing the
                        // rest of the chunk — subsequent frames may be fine.
                    }
                }
            } else {
                buffer.append(byte)
                if buffer.count > Self.maxBufferBytes {
                    buffer.removeAll(keepingCapacity: true)
                    throw FramingError.frameTooShort
                }
            }
        }
        return outputs
    }
}

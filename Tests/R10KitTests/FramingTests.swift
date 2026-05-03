import Testing
import Foundation
@testable import R10Kit

struct CobsTests {
    @Test func encodesSingleNonZeroByte() {
        #expect(Framing.cobsEncode(Data([0x01])) == Data([0x02, 0x01]))
    }

    @Test func encodesSingleZeroByte() {
        #expect(Framing.cobsEncode(Data([0x00])) == Data([0x01, 0x01]))
    }

    @Test func encodesEmbeddedZero() {
        #expect(Framing.cobsEncode(Data([0x01, 0x02, 0x00, 0x03]))
                == Data([0x03, 0x01, 0x02, 0x02, 0x03]))
    }

    @Test func roundTripsRandomBytes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<32 {
            let len = Int.random(in: 1..<400, using: &rng)
            var d = Data(count: len)
            for i in 0..<len { d[i] = UInt8.random(in: 0...255, using: &rng) }
            let enc = Framing.cobsEncode(d)
            let dec = Framing.cobsDecode(enc)
            #expect(dec == d)
        }
    }

    @Test func encodedDataContainsNoZeroBytes() {
        let input = Data([0x00, 0x01, 0x00, 0x02, 0x00, 0x03])
        let enc = Framing.cobsEncode(input)
        #expect(!enc.contains(0))
    }
}

struct Crc16Tests {
    @Test func emptyHasZeroCrc() {
        #expect(Framing.crc16(Data()) == 0x0000)
    }

    @Test func knownVectorASCII9Digits() {
        // CRC-16/ARC of "123456789" = 0xBB3D
        let s = "123456789".data(using: .ascii)!
        #expect(Framing.crc16(s) == 0xBB3D)
    }

    @Test func detectsBitFlip() {
        let a = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var b = a; b[1] ^= 0x01
        #expect(Framing.crc16(a) != Framing.crc16(b))
    }
}

struct OuterFrameTests {
    @Test func encodeDecodeRoundTrip() throws {
        let payload = Data([0xB3, 0x13, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x05, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
                            0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        let encoded = Framing.encodeOuter(payload)
        // outer must start and end with 0x00 sentinels
        #expect(encoded.first == 0x00)
        #expect(encoded.last == 0x00)
        // strip sentinels and decode
        let inner = encoded.subdata(in: (encoded.startIndex + 1)..<(encoded.endIndex - 1))
        let decoded = try Framing.decodeOuter(inner)
        #expect(decoded == payload)
    }

    @Test func decodeRejectsCrcCorruption() {
        let payload = Data([0x88, 0x13, 0xB4, 0x13, 0x00])
        let encoded = Framing.encodeOuter(payload)
        var inner = encoded.subdata(in: (encoded.startIndex + 1)..<(encoded.endIndex - 1))
        // Corrupt a byte mid-frame (not the COBS code byte at index 0)
        inner[3] ^= 0xFF
        #expect(throws: FramingError.self) { try Framing.decodeOuter(inner) }
    }
}

struct ChunkTests {
    @Test func chunksWith19BytePayloadCap() {
        let body = Data((0..<50).map { UInt8($0) })
        let chunks = Framing.chunk(body, header: 0xAB)
        #expect(chunks.count == 3)
        for c in chunks {
            #expect(c.count <= 20)
            #expect(c.first == 0xAB)
        }
        let recovered = chunks.reduce(into: Data()) { acc, c in
            acc.append(c.subdata(in: (c.startIndex + 1)..<c.endIndex))
        }
        #expect(recovered == body)
    }
}

struct ProtoEncodeTests {
    @Test func wakeUpRequestBytes() {
        // WrapperProto { service { wake_up_request {} } }
        // = field 38 length-delimited containing field 3 length-delimited containing nothing.
        // tag(38, ld) = (38<<3)|2 = 306 = varint [0xB2, 0x02]; outer len = 2
        // tag(3, ld)  = (3<<3)|2  = 26  = varint [0x1A];        inner len = 0
        let expected = Data([0xB2, 0x02, 0x02, 0x1A, 0x00])
        #expect(R10Request.wakeUp() == expected)
    }

    @Test func statusRequestBytes() {
        let expected = Data([0xB2, 0x02, 0x02, 0x0A, 0x00])
        #expect(R10Request.status() == expected)
    }

    @Test func tiltRequestBytes() {
        let expected = Data([0xB2, 0x02, 0x02, 0x2A, 0x00])
        #expect(R10Request.tilt() == expected)
    }

    @Test func subscribeLaunchMonitorBytes() {
        // WrapperProto { event { subscribe_request { alerts:[{type: LAUNCH_MONITOR=8}] } } }
        // event tag = field 30 ld = (30<<3)|2 = 242 = varint [0xF2, 0x01]
        // subscribe_request tag = field 1 ld = 0x0A
        // alerts (repeated AlertMessage) tag = field 1 ld = 0x0A
        // AlertMessage { type=8 }: tag (1<<3)|0=0x08 + varint 8 → [0x08, 0x08]
        // → AlertMessage bytes = 2; SubscribeRequest payload = [0x0A, 0x02, 0x08, 0x08] (4 bytes)
        // → EventSharing payload = [0x0A, 0x04, 0x0A, 0x02, 0x08, 0x08] (6 bytes)
        // → WrapperProto = [0xF2, 0x01, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x08, 0x08]
        let expected = Data([0xF2, 0x01, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x08, 0x08])
        #expect(R10Request.subscribe([.launchMonitor]) == expected)
    }
}

struct ProtoDecodeTests {
    @Test func parsesWakeUpResponseSuccess() throws {
        // WrapperProto { service { wake_up_response { status: SUCCESS } } }
        // service tag = [0xB2, 0x02], len = 4
        // wake_up_response tag = (4<<3)|2 = 0x22, len = 2
        // status varint: tag = (1<<3)|0 = 0x08, value = 0
        let bytes = Data([0xB2, 0x02, 0x04, 0x22, 0x02, 0x08, 0x00])
        let w = try R10WrapperProto.parse(bytes)
        #expect(w.service?.wakeStatus == .success)
    }

    @Test func parsesAlertNotificationWithClubSpeed() throws {
        // Build: WrapperProto { event { notification { type=8, AlertNotification(1001) {
        //   metrics { shot_id=42, club_metrics { club_head_speed=43.0 } } } } } }
        var w = ProtoWriter()
        w.writeMessage(field: 30) { event in
            event.writeMessage(field: 3) { notif in
                notif.writeVarint(field: 1, value: 8)
                notif.writeMessage(field: 1001) { details in
                    details.writeMessage(field: 2) { metrics in
                        metrics.writeVarint(field: 1, value: 42)
                        metrics.writeMessage(field: 4) { club in
                            club.writeFloat(field: 1, value: 43.0)
                        }
                    }
                }
            }
        }
        let parsed = try R10WrapperProto.parse(w.data)
        let metrics = parsed.event?.notification?.details?.metrics
        #expect(parsed.event?.notification?.type == .launchMonitor)
        #expect(metrics?.shotId == 42)
        #expect(metrics?.clubMetrics?.clubHeadSpeed == 43.0)
    }
}

struct AssemblerTests {
    @Test func reassemblesAcrossChunks() throws {
        let payload = Data([0xB4, 0x13, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
                            0xAA, 0xBB])
        let encoded = Framing.encodeOuter(payload)
        let chunks = Framing.chunk(encoded, header: 0x42)

        var assembler = FrameAssembler()
        assembler.markHandshakeComplete()
        var outputs: [FrameAssembler.Output] = []
        for c in chunks { outputs.append(contentsOf: try assembler.feed(c)) }

        #expect(outputs.count == 1)
        guard case .payload(let got)? = outputs.first else {
            Issue.record("expected payload output"); return
        }
        #expect(got == payload)
    }

    @Test func handshakeChunkRoutedAsHandshake() throws {
        var assembler = FrameAssembler()
        // Pre-handshake, header=0x00 means handshake response chunk.
        let chunk = Data([0x00] + Framing.handshakeResponsePrefix + [0xAB])
        let outs = try assembler.feed(chunk)
        guard case .handshake(let body)? = outs.first else {
            Issue.record("expected handshake output"); return
        }
        #expect(body.count == Framing.handshakeResponsePrefix.count + 1)
        #expect(body.last == 0xAB)
    }
}

import Testing
import Foundation
@testable import R10Kit

/// Phase A — RED then GREEN.
///
/// Per ARCHITECTURE_REVIEW L9-5: when ProtoReader.skip is called
/// (unknown field), the parser emits a structured log so we notice
/// when firmware introduces fields we don't parse. Tests verify the
/// hook fires with field number, wire type, and byte count.
///
/// Suite is `.serialized` because the handler is process-global static
/// state — parallel tests would clobber each other's captures.
@Suite(.serialized)
struct ProtoUnknownFieldTests {

    /// Reset the test capture before each test. Swift Testing creates
    /// a fresh instance per @Test, but the hook is global.
    init() {
        ProtoReader.unknownFieldHandler = nil
    }

    @Test func skippingUnknownVarintFiresHandler() throws {
        var captured: [(field: Int, wire: ProtoWireType)] = []
        ProtoReader.unknownFieldHandler = { field, wire, _ in
            captured.append((field, wire))
        }
        defer { ProtoReader.unknownFieldHandler = nil }

        var w = ProtoWriter()
        w.writeVarint(field: 42, value: 99)        // unknown to a parser that ignores it
        var r = ProtoReader(w.data)
        let (field, wire) = try r.readTag()
        try r.skip(field: field, wire: wire)

        #expect(captured.count == 1)
        #expect(captured.first?.field == 42)
        #expect(captured.first?.wire == .varint)
        #expect(field == 42)
        #expect(wire == .varint)
    }

    @Test func skippingUnknownLengthDelimitedReportsByteCount() throws {
        var captured: [(field: Int, wire: ProtoWireType, bytes: Int)] = []
        ProtoReader.unknownFieldHandler = { field, wire, bytes in
            captured.append((field, wire, bytes))
        }
        defer { ProtoReader.unknownFieldHandler = nil }

        var w = ProtoWriter()
        w.writeLengthDelimited(field: 99, bytes: Data([0x01, 0x02, 0x03, 0x04]))
        var r = ProtoReader(w.data)
        let (field, wire) = try r.readTag()
        try r.skip(field: field, wire: wire)

        #expect(captured.first?.field == 99)
        #expect(captured.first?.wire == .lengthDelimited)
        #expect(captured.first?.bytes == 4)
    }

    @Test func handlerNotCalledWhenAllFieldsKnown() throws {
        var fired = false
        ProtoReader.unknownFieldHandler = { _, _, _ in fired = true }
        defer { ProtoReader.unknownFieldHandler = nil }

        // R10ClubMetrics knows fields 1-4; pass exactly those.
        var w = ProtoWriter()
        w.writeFloat(field: 1, value: 23.0)
        _ = try R10ClubMetrics.parse(w.data)

        #expect(fired == false)
    }

    @Test func handlerCalledOnceForEachUnknownField() throws {
        var count = 0
        ProtoReader.unknownFieldHandler = { _, _, _ in count += 1 }
        defer { ProtoReader.unknownFieldHandler = nil }

        // BallMetrics now knows fields 1-7 (fields 6 + 7 — spin
        // calc type + golf ball type — were elevated from
        // "skipped" once the user mandated full-data capture).
        // Use truly out-of-range field numbers (50 + 51) so the
        // test exercises the unknown-field handler regardless of
        // future schema additions.
        var w = ProtoWriter()
        w.writeFloat(field: 3, value: 60.0)        // known: ball_speed
        w.writeVarint(field: 50, value: 0)         // unknown — future
        w.writeVarint(field: 51, value: 1)         // unknown — future
        _ = try R10BallMetrics.parse(w.data)

        #expect(count == 2)
    }
}

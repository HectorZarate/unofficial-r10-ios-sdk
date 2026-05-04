import Foundation

/// Real-byte capture of a B313 alert carrying a successful no-ball
/// PRACTICE-mode metrics payload, captured from an R10 running
/// firmware 4.50 on 2026-05-02.
///
/// Capture context:
/// - Device: R10, firmware 4.50
/// - Connection mode: BLE direct (no first-party app, no PC bridge)
/// - Subscription: LAUNCH_MONITOR alert type
/// - Swing: dry swing, no ball, full motion. Practice-classified by R10.
/// - Result: club_head_speed = 23.24 m/s = ~52.0 mph
///
/// This fixture is the primary regression-test input for the
/// `R10BallMetrics` / `R10ClubMetrics` / `R10SwingMetrics` parsers and
/// for the integrated `R10Metrics.parse` / `R10WrapperProto.parse`
/// chain.  It catches firmware quirks (length-delimited type field,
/// missing club_angle_face on no-ball swings, etc.) that synthetic
/// protobuf would not reveal.
///
/// See `R10_DATA_INVENTORY.md` "Real-byte fixture" mandate (Phase A).
enum B313_PracticeMetrics_Fixture {
    /// Bytes after stripping the BLE chunk header, the COBS sentinels,
    /// the outer length prefix, and the CRC. This is the payload that
    /// `R10Connection.handleNotification` yields to subscribers (i.e.
    /// the input to `R10Device.handleInbound`).
    static let payload: Data = Data([
        // Opcode B3 13 (proto request from device → us)
        0xB3, 0x13,
        // Counter (4 bytes LE)
        0x00, 0x00, 0x00, 0x00,
        // Two zero bytes
        0x00, 0x00,
        // Length (4 bytes LE) — value 0x00000041 = 65 protobuf bytes
        0x41, 0x00, 0x00, 0x00,
        // Length again (4 bytes LE)
        0x41, 0x00, 0x00, 0x00,
        // Protobuf payload (65 bytes) — the WrapperProto:
        //   field 30 (event/EventSharing), length 65 (0x41) — i.e. F2 01 41
        0xF2, 0x01, 0x41,
        //     field 3 (notification/AlertNotification), length 63 (0x3F) — i.e. 1A 3F
        0x1A, 0x3F,
        //       field 1 (type), encoded as length-delimited (firmware quirk),
        //       length 1, value 8 (LAUNCH_MONITOR) — i.e. 0A 01 08
        0x0A, 0x01, 0x08,
        //       field 1001 (AlertDetails), tag CA 3E, length 57 — CA 3E 39
        0xCA, 0x3E, 0x39,
        //         field 1 (state), length 2, then field 1 varint = 4 (PROCESSING)
        0x0A, 0x02, 0x08, 0x04,
        //         field 2 (metrics/R10Metrics), length 51 — 12 33
        0x12, 0x33,
        //           field 1 (shot_id), varint, value 5,539,854 (08 8E 90 D2 02)
        0x08, 0x8E, 0x90, 0xD2, 0x02,
        //           field 2 (shot_type), varint, value 0 (PRACTICE)
        0x10, 0x00,
        //           field 4 (club_metrics), length 15 — 22 0F
        0x22, 0x0F,
        //             field 1 (club_head_speed), fixed32 = 23.24 (0D 18 EC B9 41)
        0x0D, 0x18, 0xEC, 0xB9, 0x41,
        //             field 3 (club_angle_path), fixed32 = -1.622103 (1D 12 A1 CF BF)
        0x1D, 0x12, 0xA1, 0xCF, 0xBF,
        //             field 4 (attack_angle), fixed32 = 0.4974 (25 0E AB FE 3E)
        0x25, 0x0E, 0xAB, 0xFE, 0x3E,
        //           field 5 (swing_metrics), length 25 — 2A 19
        0x2A, 0x19,
        //             field 1 (back_swing_start_time), varint = 5,537,958 (08 A6 81 D2 02)
        0x08, 0xA6, 0x81, 0xD2, 0x02,
        //             field 2 (down_swing_start_time), varint = 5,539,554 (10 E2 8D D2 02)
        0x10, 0xE2, 0x8D, 0xD2, 0x02,
        //             field 3 (impact_time), varint = 5,539,854 (18 8E 90 D2 02)
        0x18, 0x8E, 0x90, 0xD2, 0x02,
        //             field 4 (follow_through_end_time), varint = 5,541,214 (20 DE 94 D2 02)
        0x20, 0xDE, 0x94, 0xD2, 0x02,
        //             field 5 (end_recording_time), varint = 5,539,874 (28 A2 91 D2 02)
        0x28, 0xA2, 0x91, 0xD2, 0x02,
    ])

    /// Just the protobuf bytes (offset 16 into payload). Convenient for
    /// directly testing R10WrapperProto.parse without the BLE/opcode
    /// envelope.
    static let protoBytes: Data = payload.subdata(in: 16..<payload.endIndex)

    // Expected decoded values. Floats are declared as `Float(bitPattern:)`
    // so the test asserts EXACTLY what the bytes encode — not what the
    // literal "23.24" rounds to (those differ in the last few bits).
    static let expectedShotId: UInt32 = 5_539_854
    static let expectedClubHeadSpeedMPS = Float(bitPattern: 0x41B9_EC18)   // ≈23.24 m/s ≈ 52.0 mph
    static let expectedClubAnglePath   = Float(bitPattern: 0xBFCF_A112)   // ≈-1.622103
    static let expectedAttackAngle      = Float(bitPattern: 0x3EFE_AB0E)   // ≈0.4974
    static let expectedBackSwingStartMs: UInt32 = 5_537_958
    static let expectedDownSwingStartMs: UInt32 = 5_539_554
    static let expectedImpactMs: UInt32 = 5_539_854
}

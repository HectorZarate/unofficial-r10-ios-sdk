import Testing
import Foundation
@testable import R10Kit

/// Phase A — RED then GREEN.
///
/// Validates that R10ErrorInfo extracts the device-tilt sub-message
/// (field 3 of Error). When the R10 fires a PLATFORM_TILTED error,
/// it includes the actual roll/pitch angles — currently dropped.
struct ErrorParsingTests {

    @Test func parsesAllErrorFields() throws {
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 3)            // code = PLATFORM_TILTED
        w.writeVarint(field: 2, value: 0)            // severity = WARNING
        w.writeMessage(field: 3) { tilt in           // deviceTilt
            tilt.writeFloat(field: 1, value: -3.7)   // roll
            tilt.writeFloat(field: 2, value: 17.0)   // pitch
        }

        let parsed = try R10ErrorInfo.parse(w.data)

        #expect(parsed.code == .platformTilted)
        #expect(parsed.severity == .warning)
        #expect(parsed.deviceTilt?.roll == -3.7)
        #expect(parsed.deviceTilt?.pitch == 17.0)
    }

    @Test func tiltAbsentWhenNotInPayload() throws {
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 1)            // OVERHEATING
        w.writeVarint(field: 2, value: 2)            // FATAL
        let parsed = try R10ErrorInfo.parse(w.data)
        #expect(parsed.code == .overheating)
        #expect(parsed.severity == .fatal)
        #expect(parsed.deviceTilt == nil)
    }

    @Test func tiltOnlyPayloadStillParses() throws {
        // Some firmware error frames carry only the tilt sub-message
        // without code/severity. Parser should accept this gracefully.
        var w = ProtoWriter()
        w.writeMessage(field: 3) { tilt in
            tilt.writeFloat(field: 1, value: 0.4)
            tilt.writeFloat(field: 2, value: 17.07)
        }
        let parsed = try R10ErrorInfo.parse(w.data)
        #expect(parsed.code == nil)
        #expect(parsed.severity == nil)
        #expect(parsed.deviceTilt?.roll == 0.4)
        #expect(parsed.deviceTilt?.pitch == 17.07)
    }
}

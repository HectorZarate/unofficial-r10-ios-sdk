import Testing
import Foundation
@testable import R10Kit

/// Phase A — RED then GREEN.
///
/// AlertSupportResponse fingerprints the firmware's supported alert
/// types and protocol version. Sent in response to an
/// AlertSupportRequest we issue at handshake completion. May surface
/// undocumented alert types in firmware 4.50+ (per resolved I1 in
/// R10_DATA_INVENTORY).
///
/// ShotConfigResponse acknowledges our ShotConfigRequest with a bool.
struct AlertSupportResponseTests {

    @Test func parsesSupportedAlertsList() throws {
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 0)         // ACTIVITY_START
        w.writeVarint(field: 1, value: 1)         // ACTIVITY_STOP
        w.writeVarint(field: 1, value: 8)         // LAUNCH_MONITOR
        w.writeVarint(field: 2, value: 42)        // version_number

        let parsed = try R10AlertSupportResponse.parse(w.data)

        #expect(parsed.supportedAlerts == [.activityStart, .activityStop, .launchMonitor])
        #expect(parsed.versionNumber == 42)
    }

    @Test func emptyPayloadProducesEmptyList() throws {
        let parsed = try R10AlertSupportResponse.parse(Data())
        #expect(parsed.supportedAlerts.isEmpty)
        #expect(parsed.versionNumber == nil)
    }

    @Test func unknownAlertValuesPreservedAsUnknown() throws {
        // If firmware 4.50 introduces alert type 9 we don't know about,
        // we still want the count + a marker — surface it diagnostically.
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 9)         // unknown to our enum
        w.writeVarint(field: 1, value: 8)
        let parsed = try R10AlertSupportResponse.parse(w.data)
        #expect(parsed.supportedAlerts.count == 2)
        #expect(parsed.supportedAlerts.contains(.unknown))
        #expect(parsed.supportedAlerts.contains(.launchMonitor))
    }
}

struct AlertSupportRequestBuilderTests {

    @Test func emitsCorrectWireBytes() {
        // WrapperProto { event { support_request {} } }
        // event tag = field 30 ld = (30<<3)|2 = 242 → varint [F2, 01]
        // event len = 2
        // support_request tag = field 4 ld = (4<<3)|2 = 0x22; len = 0
        let expected = Data([0xF2, 0x01, 0x02, 0x22, 0x00])
        #expect(R10Request.alertSupportQuery() == expected)
    }
}

struct EventSharingExtendedTests {

    @Test func parsesAlertSupportResponseInEventSharing() throws {
        // EventSharing.support_response is field 5.
        var inner = ProtoWriter()
        inner.writeVarint(field: 1, value: 8)
        inner.writeVarint(field: 2, value: 1)
        var w = ProtoWriter()
        w.writeLengthDelimited(field: 5, bytes: inner.data)

        let parsed = try R10EventSharing.parse(w.data)
        #expect(parsed.supportResponse?.supportedAlerts == [.launchMonitor])
        #expect(parsed.supportResponse?.versionNumber == 1)
    }
}

struct ShotConfigResponseTests {

    @Test func parsesSuccessTrue() throws {
        var w = ProtoWriter()
        w.writeBool(field: 1, value: true)
        let parsed = try R10ShotConfigResponse.parse(w.data)
        #expect(parsed.success == true)
    }

    @Test func parsesSuccessFalse() throws {
        var w = ProtoWriter()
        w.writeBool(field: 1, value: false)
        let parsed = try R10ShotConfigResponse.parse(w.data)
        #expect(parsed.success == false)
    }

    @Test func emptyResponseHasNilSuccess() throws {
        let parsed = try R10ShotConfigResponse.parse(Data())
        #expect(parsed.success == nil)
    }
}

struct ServiceResponseExtendedTests {

    @Test func parsesShotConfigResponseInService() throws {
        // LaunchMonitorService.shot_config_response is field 12.
        var inner = ProtoWriter()
        inner.writeBool(field: 1, value: true)
        var w = ProtoWriter()
        w.writeLengthDelimited(field: 12, bytes: inner.data)

        let parsed = try R10ServiceResponse.parse(w.data)
        #expect(parsed.shotConfigResponse?.success == true)
    }
}

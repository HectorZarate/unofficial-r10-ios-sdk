import Foundation

public enum R10StateType: Int {
    case standby = 0
    case interferenceTest = 1
    case waiting = 2
    case recording = 3
    case processing = 4
    case error = 5
    case unknown = -1

    static func from(_ raw: UInt64) -> R10StateType { R10StateType(rawValue: Int(raw)) ?? .unknown }
}

public enum R10AlertType: Int {
    case activityStart = 0
    case activityStop = 1
    case launchMonitor = 8
    case unknown = -1

    static func from(_ raw: UInt64) -> R10AlertType { R10AlertType(rawValue: Int(raw)) ?? .unknown }
}

public enum R10WakeStatus: Int {
    case success = 0
    case alreadyAwake = 1
    case unknownError = 2
    case unknown = -1

    static func from(_ raw: UInt64) -> R10WakeStatus { R10WakeStatus(rawValue: Int(raw)) ?? .unknown }
}

public enum R10ErrorCode: Int {
    case unknown = 0
    case overheating = 1
    case radarSaturation = 2
    case platformTilted = 3
}

public enum R10Severity: Int {
    case warning = 0
    case serious = 1
    case fatal = 2
}

public enum R10CalibrationStatusType: Int {
    case unknown = 0
    case inBounds = 1
    case recalibrationSuggested = 2
    case recalibrationRequired = 3
}

public struct R10Tilt {
    public var roll: Float?
    public var pitch: Float?

    public static func parse(_ data: Data) throws -> R10Tilt {
        var r = ProtoReader(data); var t = R10Tilt()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .fixed32): t.roll = try r.readFloat()
            case (2, .fixed32): t.pitch = try r.readFloat()
            default: try r.skip(field: field, wire: wire)
            }
        }
        return t
    }
}

public enum R10ShotType: Int {
    case practice = 0
    case normal = 1
    case unknown = -1

    static func from(_ raw: UInt64) -> R10ShotType { R10ShotType(rawValue: Int(raw)) ?? .unknown }
}

public struct R10ClubMetrics {
    public var clubHeadSpeed: Float?
    public var clubAngleFace: Float?
    public var clubAnglePath: Float?
    public var attackAngle: Float?

    public static func parse(_ data: Data) throws -> R10ClubMetrics {
        var r = ProtoReader(data); var m = R10ClubMetrics()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .fixed32): m.clubHeadSpeed = try r.readFloat()
            case (2, .fixed32): m.clubAngleFace = try r.readFloat()
            case (3, .fixed32): m.clubAnglePath = try r.readFloat()
            case (4, .fixed32): m.attackAngle = try r.readFloat()
            default: try r.skip(field: field, wire: wire)
            }
        }
        return m
    }
}

/// Provenance for the spin number — RATIO/BALL_FLIGHT/OTHER are
/// inferred; MEASURED is direct radar. Useful when reviewing
/// shots with unexpected spin values.
public enum R10SpinCalcType: Int, Sendable {
    case ratio = 0
    case ballFlight = 1
    case other = 2
    case measured = 3

    public var displayName: String {
        switch self {
        case .ratio:       return "Ratio (inferred)"
        case .ballFlight:  return "Ball flight"
        case .other:       return "Other"
        case .measured:    return "Measured"
        }
    }
}

/// What the R10 thinks it's looking at — affects spin accuracy.
public enum R10GolfBallType: Int, Sendable {
    case unknown = 0
    case conventional = 1
    case marked = 2

    public var displayName: String {
        switch self {
        case .unknown:      return "Unknown"
        case .conventional: return "Conventional"
        case .marked:       return "Marked"
        }
    }
}

/// Ball-flight metrics from R10 radar after a real ball strike.
/// Absent on no-ball practice swings (the radar has nothing to measure).
public struct R10BallMetrics {
    public var launchAngle: Float?
    public var launchDirection: Float?
    public var ballSpeed: Float?
    public var spinAxis: Float?
    public var totalSpin: Float?
    public var spinCalcType: R10SpinCalcType?
    public var golfBallType: R10GolfBallType?

    public static func parse(_ data: Data) throws -> R10BallMetrics {
        var r = ProtoReader(data); var m = R10BallMetrics()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .fixed32): m.launchAngle = try r.readFloat()
            case (2, .fixed32): m.launchDirection = try r.readFloat()
            case (3, .fixed32): m.ballSpeed = try r.readFloat()
            case (4, .fixed32): m.spinAxis = try r.readFloat()
            case (5, .fixed32): m.totalSpin = try r.readFloat()
            case (6, .varint):
                // Unknown enum values stay nil — forward-compat
                // when firmware adds a 4th case.
                m.spinCalcType = R10SpinCalcType(rawValue: Int(try r.readVarint()))
            case (7, .varint):
                m.golfBallType = R10GolfBallType(rawValue: Int(try r.readVarint()))
            default: try r.skip(field: field, wire: wire)
            }
        }
        return m
    }
}

public struct R10SwingMetrics {
    public var backSwingStartTime: UInt32?
    public var downSwingStartTime: UInt32?
    public var impactTime: UInt32?
    public var followThroughEndTime: UInt32?
    public var endRecordingTime: UInt32?

    public static func parse(_ data: Data) throws -> R10SwingMetrics {
        var r = ProtoReader(data); var m = R10SwingMetrics()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint): m.backSwingStartTime = UInt32(truncatingIfNeeded: try r.readVarint())
            case (2, .varint): m.downSwingStartTime = UInt32(truncatingIfNeeded: try r.readVarint())
            case (3, .varint): m.impactTime = UInt32(truncatingIfNeeded: try r.readVarint())
            case (4, .varint): m.followThroughEndTime = UInt32(truncatingIfNeeded: try r.readVarint())
            case (5, .varint): m.endRecordingTime = UInt32(truncatingIfNeeded: try r.readVarint())
            default: try r.skip(field: field, wire: wire)
            }
        }
        return m
    }
}

public struct R10Metrics {
    public var shotId: UInt32?
    public var shotType: R10ShotType?
    public var ballMetrics: R10BallMetrics?
    public var clubMetrics: R10ClubMetrics?
    public var swingMetrics: R10SwingMetrics?

    public static func parse(_ data: Data) throws -> R10Metrics {
        var r = ProtoReader(data); var m = R10Metrics()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint):
                m.shotId = UInt32(truncatingIfNeeded: try r.readVarint())
            case (2, .varint):
                m.shotType = R10ShotType.from(try r.readVarint())
            case (3, .lengthDelimited):
                m.ballMetrics = try R10BallMetrics.parse(try r.readLengthDelimited())
            case (4, .lengthDelimited):
                m.clubMetrics = try R10ClubMetrics.parse(try r.readLengthDelimited())
            case (5, .lengthDelimited):
                m.swingMetrics = try R10SwingMetrics.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return m
    }
}

public struct R10ErrorInfo {
    public var code: R10ErrorCode?
    public var severity: R10Severity?
    /// Tilt at the moment the error fired. Populated for tilt-related
    /// errors and for some firmware-emitted "still tilted" status frames
    /// that have no code/severity.
    public var deviceTilt: R10Tilt?

    public static func parse(_ data: Data) throws -> R10ErrorInfo {
        var r = ProtoReader(data); var e = R10ErrorInfo()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint):
                e.code = R10ErrorCode(rawValue: Int(try r.readVarint()))
            case (2, .varint):
                e.severity = R10Severity(rawValue: Int(try r.readVarint()))
            case (3, .lengthDelimited):
                e.deviceTilt = try R10Tilt.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return e
    }
}

public struct R10AlertDetails {
    public var state: R10StateType?
    public var metrics: R10Metrics?
    public var error: R10ErrorInfo?
    public var calibrationStatus: R10CalibrationStatusType?

    public static func parse(_ data: Data) throws -> R10AlertDetails {
        var r = ProtoReader(data); var a = R10AlertDetails()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .lengthDelimited):
                var sr = ProtoReader(try r.readLengthDelimited())
                while !sr.isAtEnd {
                    let (sf, sw) = try sr.readTag()
                    if sf == 1, sw == .varint { a.state = R10StateType.from(try sr.readVarint()) }
                    else { try sr.skip(field: sf, wire: sw) }
                }
            case (2, .lengthDelimited):
                a.metrics = try R10Metrics.parse(try r.readLengthDelimited())
            case (3, .lengthDelimited):
                a.error = try R10ErrorInfo.parse(try r.readLengthDelimited())
            case (4, .lengthDelimited):
                var cr = ProtoReader(try r.readLengthDelimited())
                while !cr.isAtEnd {
                    let (cf, cw) = try cr.readTag()
                    if cf == 1, cw == .varint { a.calibrationStatus = R10CalibrationStatusType(rawValue: Int(try cr.readVarint())) }
                    else { try cr.skip(field: cf, wire: cw) }
                }
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return a
    }
}

public struct R10AlertNotification {
    public var type: R10AlertType?
    public var details: R10AlertDetails?

    public static func parse(_ data: Data) throws -> R10AlertNotification {
        var r = ProtoReader(data); var n = R10AlertNotification()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint):
                n.type = R10AlertType.from(try r.readVarint())
            case (1, .lengthDelimited):
                // Firmware quirk: R10 4.50 sends `type` as a single-byte
                // length-delimited blob (e.g. `0A 01 08` for LAUNCH_MONITOR)
                // rather than the standard varint encoding (`08 08`). Both
                // forms decode to the same enum value.
                let inner = try r.readLengthDelimited()
                if let first = inner.first {
                    n.type = R10AlertType.from(UInt64(first))
                }
            case (1001, .lengthDelimited):
                n.details = try R10AlertDetails.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return n
    }
}

public struct R10SubscribeStatus {
    public var alertType: R10AlertType?
    public var success: Bool?
}

public struct R10SubscribeResponse {
    public var statuses: [R10SubscribeStatus] = []

    public static func parse(_ data: Data) throws -> R10SubscribeResponse {
        var r = ProtoReader(data); var s = R10SubscribeResponse()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .lengthDelimited):
                var sr = ProtoReader(try r.readLengthDelimited())
                var status = R10SubscribeStatus()
                while !sr.isAtEnd {
                    let (sf, sw) = try sr.readTag()
                    switch (sf, sw) {
                    case (1, .varint):
                        status.success = (try sr.readVarint()) == 0
                    case (2, .lengthDelimited):
                        var tr = ProtoReader(try sr.readLengthDelimited())
                        while !tr.isAtEnd {
                            let (tf, tw) = try tr.readTag()
                            if tf == 1, tw == .varint { status.alertType = R10AlertType.from(try tr.readVarint()) }
                            else { try tr.skip(field: tf, wire: tw) }
                        }
                    default:
                        try sr.skip(field: sf, wire: sw)
                    }
                }
                s.statuses.append(status)
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return s
    }
}

/// Response to an AlertSupportRequest. Fingerprints the firmware's
/// supported alert types and protocol version. Sent in response to a
/// query at handshake completion — gives us a diagnostic toehold for
/// detecting newer-firmware-only alert types.
public struct R10AlertSupportResponse {
    public var supportedAlerts: [R10AlertType] = []
    public var versionNumber: UInt32?

    public static func parse(_ data: Data) throws -> R10AlertSupportResponse {
        var r = ProtoReader(data); var s = R10AlertSupportResponse()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint):
                s.supportedAlerts.append(R10AlertType.from(try r.readVarint()))
            case (2, .varint):
                s.versionNumber = UInt32(truncatingIfNeeded: try r.readVarint())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return s
    }
}

public struct R10EventSharing {
    public var subscribeResponse: R10SubscribeResponse?
    public var notification: R10AlertNotification?
    public var supportResponse: R10AlertSupportResponse?

    public static func parse(_ data: Data) throws -> R10EventSharing {
        var r = ProtoReader(data); var e = R10EventSharing()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (2, .lengthDelimited):
                e.subscribeResponse = try R10SubscribeResponse.parse(try r.readLengthDelimited())
            case (3, .lengthDelimited):
                e.notification = try R10AlertNotification.parse(try r.readLengthDelimited())
            case (5, .lengthDelimited):
                e.supportResponse = try R10AlertSupportResponse.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return e
    }
}

/// Response to a ShotConfigRequest — confirms whether the configuration
/// (temperature, humidity, altitude, air_density, tee_range) was applied.
public struct R10ShotConfigResponse {
    public var success: Bool?

    public static func parse(_ data: Data) throws -> R10ShotConfigResponse {
        var r = ProtoReader(data); var s = R10ShotConfigResponse()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, .varint):
                s.success = try r.readBool()
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return s
    }
}

public struct R10ServiceResponse {
    public var statusState: R10StateType?
    public var wakeStatus: R10WakeStatus?
    public var tilt: R10Tilt?
    public var shotConfigResponse: R10ShotConfigResponse?

    public static func parse(_ data: Data) throws -> R10ServiceResponse {
        var r = ProtoReader(data); var s = R10ServiceResponse()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (2, .lengthDelimited):
                var sr = ProtoReader(try r.readLengthDelimited())
                while !sr.isAtEnd {
                    let (sf, sw) = try sr.readTag()
                    if sf == 1, sw == .varint { s.statusState = R10StateType.from(try sr.readVarint()) }
                    else { try sr.skip(field: sf, wire: sw) }
                }
            case (4, .lengthDelimited):
                var wr = ProtoReader(try r.readLengthDelimited())
                while !wr.isAtEnd {
                    let (wf, ww) = try wr.readTag()
                    if wf == 1, ww == .varint { s.wakeStatus = R10WakeStatus.from(try wr.readVarint()) }
                    else { try wr.skip(field: wf, wire: ww) }
                }
            case (6, .lengthDelimited):
                var tr = ProtoReader(try r.readLengthDelimited())
                var t = R10Tilt()
                while !tr.isAtEnd {
                    let (tf, tw) = try tr.readTag()
                    switch (tf, tw) {
                    case (1, .lengthDelimited):
                        t = try R10Tilt.parse(try tr.readLengthDelimited())
                    default:
                        try tr.skip(field: tf, wire: tw)
                    }
                }
                s.tilt = t
            case (12, .lengthDelimited):
                s.shotConfigResponse = try R10ShotConfigResponse.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return s
    }
}

public struct R10WrapperProto {
    public var event: R10EventSharing?
    public var service: R10ServiceResponse?

    public static func parse(_ data: Data) throws -> R10WrapperProto {
        var r = ProtoReader(data); var w = R10WrapperProto()
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (30, .lengthDelimited):
                w.event = try R10EventSharing.parse(try r.readLengthDelimited())
            case (38, .lengthDelimited):
                w.service = try R10ServiceResponse.parse(try r.readLengthDelimited())
            default:
                try r.skip(field: field, wire: wire)
            }
        }
        return w
    }
}

public enum R10Request {
    static func wakeUp() -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 38) { service in
            service.writeMessage(field: 3) { _ in }
        }
        return w.data
    }

    static func status() -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 38) { service in
            service.writeMessage(field: 1) { _ in }
        }
        return w.data
    }

    static func tilt() -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 38) { service in
            service.writeMessage(field: 5) { _ in }
        }
        return w.data
    }

    /// Capability query — fingerprints firmware supported alert types
    /// and protocol version. Sent at handshake completion.
    static func alertSupportQuery() -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 30) { event in
            event.writeMessage(field: 4) { _ in }
        }
        return w.data
    }

    static func subscribe(_ types: [R10AlertType]) -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 30) { event in
            event.writeMessage(field: 1) { req in
                for t in types {
                    req.writeMessage(field: 1) { alert in
                        alert.writeVarint(field: 1, value: UInt64(t.rawValue))
                    }
                }
            }
        }
        return w.data
    }

    /// Pre-configure the shot environment. mholow's GUI lets the user fill
    /// these in; we send a default that approximates a sea-level indoor
    /// environment with tee_range set to the conventional 6 feet.
    static func shotConfig(temperatureF: Float = 70,
                           humidity: Float = 0.5,
                           altitudeFt: Float = 0,
                           airDensity: Float = 1.225,
                           teeRangeFt: Float = 6.0) -> Data {
        var w = ProtoWriter()
        w.writeMessage(field: 38) { service in
            service.writeMessage(field: 11) { config in
                config.writeFloat(field: 1, value: temperatureF)
                config.writeFloat(field: 2, value: humidity)
                config.writeFloat(field: 3, value: altitudeFt)
                config.writeFloat(field: 4, value: airDensity)
                config.writeFloat(field: 5, value: teeRangeFt)
            }
        }
        return w.data
    }
}

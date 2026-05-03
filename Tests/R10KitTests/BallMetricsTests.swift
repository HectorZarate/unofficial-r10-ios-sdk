import Testing
import Foundation
@testable import R10Kit

/// Phase A — RED then GREEN.
///
/// Validates the R10BallMetrics parser (currently absent) and the
/// extended R10Metrics.parse handling field 3 (ball_metrics).
/// Expectation: every R10 ball-flight number captured per shot.
struct BallMetricsTests {

    @Test func parsesAllFiveBallMetricFloats() throws {
        var w = ProtoWriter()
        w.writeFloat(field: 1, value: 12.4)        // launch_angle
        w.writeFloat(field: 2, value: -1.8)        // launch_direction
        w.writeFloat(field: 3, value: 64.0)        // ball_speed (m/s)
        w.writeFloat(field: 4, value: -3.0)        // spin_axis
        w.writeFloat(field: 5, value: 2400.0)      // total_spin

        let parsed = try R10BallMetrics.parse(w.data)

        #expect(parsed.launchAngle == 12.4)
        #expect(parsed.launchDirection == -1.8)
        #expect(parsed.ballSpeed == 64.0)
        #expect(parsed.spinAxis == -3.0)
        #expect(parsed.totalSpin == 2400.0)
    }

    @Test func emptyBytesProducesAllNil() throws {
        let parsed = try R10BallMetrics.parse(Data())
        #expect(parsed.ballSpeed == nil)
        #expect(parsed.launchAngle == nil)
        #expect(parsed.launchDirection == nil)
        #expect(parsed.spinAxis == nil)
        #expect(parsed.totalSpin == nil)
    }

    @Test func partialPayloadProducesPartialMetrics() throws {
        // Only ball_speed populated — common when R10 only partially
        // resolves a swing.
        var w = ProtoWriter()
        w.writeFloat(field: 3, value: 80.0)
        let parsed = try R10BallMetrics.parse(w.data)
        #expect(parsed.ballSpeed == 80.0)
        #expect(parsed.launchAngle == nil)
        #expect(parsed.totalSpin == nil)
    }

    @Test func skipsUnknownFields() throws {
        // Forward-compatibility: an unknown field 99 must not crash
        // or corrupt subsequent parses.
        var w = ProtoWriter()
        w.writeFloat(field: 3, value: 64.0)
        w.writeFloat(field: 99, value: 999.0)      // unknown
        w.writeFloat(field: 1, value: 12.4)
        let parsed = try R10BallMetrics.parse(w.data)
        #expect(parsed.ballSpeed == 64.0)
        #expect(parsed.launchAngle == 12.4)
    }

    /// Per-shot data inventory mandate: every R10 field must be
    /// captured even if not displayed. The provenance enums
    /// (spin_calculation_type, golf_ball_type) tell us *how* the
    /// numbers were derived — important for debugging when a shot
    /// looks weird (e.g. RATIO-derived spin is less reliable than
    /// MEASURED).
    @Test func parsesSpinCalculationType() throws {
        var w = ProtoWriter()
        w.writeFloat(field: 3, value: 60.0)        // ball_speed
        w.writeVarint(field: 6, value: 3)          // spin_calc = MEASURED
        let parsed = try R10BallMetrics.parse(w.data)
        #expect(parsed.spinCalcType == .measured)
    }

    @Test func parsesAllSpinCalculationTypes() throws {
        for (raw, expected) in [
            (0, R10SpinCalcType.ratio),
            (1, .ballFlight),
            (2, .other),
            (3, .measured),
        ] {
            var w = ProtoWriter()
            w.writeVarint(field: 6, value: UInt64(raw))
            let parsed = try R10BallMetrics.parse(w.data)
            #expect(parsed.spinCalcType == expected)
        }
    }

    @Test func parsesGolfBallType() throws {
        var w = ProtoWriter()
        w.writeVarint(field: 7, value: 2)          // golf_ball = MARKED
        let parsed = try R10BallMetrics.parse(w.data)
        #expect(parsed.golfBallType == .marked)
    }

    @Test func parsesAllGolfBallTypes() throws {
        for (raw, expected) in [
            (0, R10GolfBallType.unknown),
            (1, .conventional),
            (2, .marked),
        ] {
            var w = ProtoWriter()
            w.writeVarint(field: 7, value: UInt64(raw))
            let parsed = try R10BallMetrics.parse(w.data)
            #expect(parsed.golfBallType == expected)
        }
    }

    @Test func unknownEnumValuesRoundTripAsNil() throws {
        // Forward-compat: a future firmware revision adds a new
        // SpinCalcType case = 4. Today's parser must NOT crash;
        // it just records unknown.
        var w = ProtoWriter()
        w.writeVarint(field: 6, value: 99)
        let parsed = try R10BallMetrics.parse(w.data)
        #expect(parsed.spinCalcType == nil)
    }
}

struct ExtendedR10MetricsTests {

    @Test func parsesBothBallAndClubMetrics() throws {
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 12345)              // shot_id
        w.writeVarint(field: 2, value: 1)                  // shot_type = NORMAL
        w.writeMessage(field: 3) { ball in                 // ball_metrics
            ball.writeFloat(field: 3, value: 60.0)
            ball.writeFloat(field: 1, value: 12.4)
        }
        w.writeMessage(field: 4) { club in                 // club_metrics
            club.writeFloat(field: 1, value: 40.0)
            club.writeFloat(field: 2, value: 1.5)
        }

        let parsed = try R10Metrics.parse(w.data)

        #expect(parsed.shotId == 12345)
        #expect(parsed.shotType == .normal)
        #expect(parsed.ballMetrics?.ballSpeed == 60.0)
        #expect(parsed.ballMetrics?.launchAngle == 12.4)
        #expect(parsed.clubMetrics?.clubHeadSpeed == 40.0)
        #expect(parsed.clubMetrics?.clubAngleFace == 1.5)
    }

    @Test func ballMetricsNilWhenAbsent() throws {
        // No-ball practice swing has club_metrics but no ball_metrics.
        var w = ProtoWriter()
        w.writeVarint(field: 1, value: 999)
        w.writeMessage(field: 4) { club in
            club.writeFloat(field: 1, value: 23.0)
        }
        let parsed = try R10Metrics.parse(w.data)
        #expect(parsed.clubMetrics?.clubHeadSpeed == 23.0)
        #expect(parsed.ballMetrics == nil)
    }
}

struct PracticeMetricsFixtureTests {

    /// Round-trips the captured-from-real-hardware bytes through
    /// the extended R10WrapperProto parser. The metrics extracted
    /// must match what the device printed in the user's logs.
    @Test func parsesRealNoBallPracticeShot() throws {
        let parsed = try R10WrapperProto.parse(B313_PracticeMetrics_Fixture.protoBytes)
        let metrics = parsed.event?.notification?.details?.metrics

        #expect(metrics?.shotId == B313_PracticeMetrics_Fixture.expectedShotId)
        #expect(metrics?.shotType == .practice)
        #expect(metrics?.clubMetrics?.clubHeadSpeed == B313_PracticeMetrics_Fixture.expectedClubHeadSpeedMPS)
        #expect(metrics?.clubMetrics?.clubAnglePath == B313_PracticeMetrics_Fixture.expectedClubAnglePath)
        #expect(metrics?.clubMetrics?.attackAngle == B313_PracticeMetrics_Fixture.expectedAttackAngle)
        // No ball strike → no ball metrics, no club face.
        #expect(metrics?.ballMetrics == nil)
        #expect(metrics?.clubMetrics?.clubAngleFace == nil)
        // Swing timing should be fully populated.
        #expect(metrics?.swingMetrics?.backSwingStartTime == B313_PracticeMetrics_Fixture.expectedBackSwingStartMs)
        #expect(metrics?.swingMetrics?.downSwingStartTime == B313_PracticeMetrics_Fixture.expectedDownSwingStartMs)
        #expect(metrics?.swingMetrics?.impactTime == B313_PracticeMetrics_Fixture.expectedImpactMs)
    }

    /// The fixture also exercises the AlertNotification.type
    /// length-delimited quirk (firmware sends 0A 01 08, not 08 08).
    /// Once the parser handles it, type should be .launchMonitor.
    @Test func extractsLaunchMonitorAlertTypeFromFixture() throws {
        let parsed = try R10WrapperProto.parse(B313_PracticeMetrics_Fixture.protoBytes)
        #expect(parsed.event?.notification?.type == .launchMonitor)
    }
}

# Changelog

All notable changes to R10Kit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial public release of R10Kit, extracted from the Swing Speed app.
- `R10Connection` actor for BLE transport.
- `R10Device` actor for proto parsing and request/response correlation.
- `R10ShotEvent` with full ball, club, and swing-timing metrics.
- `R10TimeBase` for converting R10 ms-since-boot timestamps to wall clock.
- `R10SpinCalcType` and `R10GolfBallType` provenance enums.
- 58 unit tests covering framing (COBS, CRC-16, frame assembly), proto
  parsing (ball metrics, error parsing, capability response, unknown-
  field handling), time-base, and the swing-rejection detector.
- Real-byte regression fixture (`B313_PracticeMetrics_Fixture`) from
  actual R10 hardware.
- Demo iOS app at the repo root showing connection state and shot list.

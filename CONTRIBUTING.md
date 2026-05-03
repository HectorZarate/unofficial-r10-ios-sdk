# Contributing to R10Kit

Thanks for your interest. The protocol layer is built on
reverse-engineered work from real device traffic; that means there's
genuinely useful work to do as new firmware revisions ship and edge
cases appear that nobody's seen yet.

## Quick checks before opening a PR

- `swift build` succeeds.
- `swift test` passes (58 tests today; please don't decrement).
- New behavior is covered by a test. Real-byte regression fixtures
  preferred over synthetic — see `Tests/R10KitTests/Fixtures/` for
  the existing format.
- Public API changes preserve source compatibility OR are clearly
  motivated in the PR description.

## What kinds of contributions are welcome

- **New proto message types** — there are several R10 messages we
  don't parse yet (R10ServiceResponse extras, ShotConfigResponse
  fields, alert variants).
- **Hardware bug reports + fixtures** — if your R10 emits something
  the parser logs as an unknown field, capture the raw bytes and open
  an issue with the fixture.
- **CI / tooling** — better GitHub Actions, coverage reporting, doc
  generation.
- **Examples** — additional sample apps (SwiftUI, UIKit, watchOS,
  Mac Catalyst) showing how to integrate.
- **Documentation** — DocC catalog, more API docstrings.
- **Performance** — the framing layer hasn't been profiled. There's
  likely room.

## What we'll likely push back on

- **Public API churn** without a clear motivation. We want the SDK
  to be stable for downstream consumers.
- **Adding heavy dependencies** — the package today has zero
  third-party deps. Keep it that way unless it's truly necessary.
- **App-level features** (UI, persistence, networking) — those go in
  *consumers* of the SDK, not in the SDK itself.
- **Trajectory simulators / ballistics models** — out of scope; the
  SDK gives you launch + spin; you compute the rest.

## Development setup

```bash
git clone https://github.com/<your-org>/unofficial-r10-ios-sdk
cd unofficial-r10-ios-sdk
swift test
```

The package builds on macOS standalone via `swift build` /
`swift test`. The demo app at the repo root requires Xcode + a
manual "Add Local Package" step (see README "Run the demo app").

## Hardware testing

The R10 doesn't fit in a CI runner. Hardware verification is on
the contributor. If you're modifying the framing or proto layers
and don't have access to a device, mention that in the PR — we'll
help validate from our end.

## License

By submitting a PR you agree to license your contribution under the
[MIT License](LICENSE).

---
name: Bug report
about: Something isn't working as documented
title: ''
labels: bug
---

**Describe the bug**
A clear and concise description of what the bug is.

**To reproduce**
Steps to reproduce the behavior:
1. Connect to R10 firmware version: …
2. Call `…`
3. Observe `…`

**Expected behavior**
What you expected to happen.

**Hardware**
- iPhone model + iOS version:
- R10 firmware (visible in Settings → R10 in the demo app):
- Other apps using BLE during the test (Garmin Connect, etc.):

**R10Kit version**
e.g. `0.1.0` or commit hash if installed from main.

**Log output**
If the issue is in the protocol layer, run with `#if DEBUG` enabled
and paste relevant `[R10] …` log lines.

**Real-byte capture (optional but very helpful for parser bugs)**
If the parser is dropping or misinterpreting a payload, the most
useful thing is the raw bytes. From a debug session you can grab
the inbound `Data` from `R10Connection.inboundPayloads` and
hex-dump it.

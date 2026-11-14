# DL-TDoA callback-path audit (Mac / physical iPhone)

## Verified API

Apple static DocC JSON (retrieved 2026-11-14):
https://developer.apple.com/tutorials/data/documentation/nearbyinteraction/nisessiondelegate/session(_:didupdatedltdoa:).json

The Swift declaration is:
```swift
optional func session(_ session: NISession, didUpdateDLTDOA measurements: [NIDLTDOAMeasurement])
```
The Objective-C selector is `session:didUpdateDLTDOAMeasurements:`. The existing Swift method matches; do not rename its label to the Objective-C spelling. Because this requirement is optional, merely conforming to `NISessionDelegate` does not prove a similarly named method is a protocol witness.

## Build / protocol check on a Mac

Use Xcode with the iOS 26+ SDK selected (`xcode-select -p`, `xcrun --sdk iphoneos --show-sdk-version`). Open the project, select the app target, and Command-click `NISessionDelegate` / use Jump to Definition to inspect the **installed SDK** generated interface and method availability. Check its method label and parameter type against the declaration above. Build the actual target (not a standalone mock protocol):

```sh
cd Samples/iOS/DLTDOAReceiver
xcodebuild -project DLTDOAReceiver.xcodeproj -scheme DLTDOAReceiver \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

This checks SDK type/isolation compatibility, not signing, entitlements, RF reception, or delegate delivery. Then sign and run on the supported physical iPhone. This change was statically inspected on Windows; no Xcode build or actual reception test was possible here.

## Breakpoints and Console

1. Set a **source breakpoint on the first `callbackAudit.enter(session)` line** in `session(_:didUpdateDLTDOA:)`, before mapping measurements and before the MainActor Task. In Debug, its hit proves entry independently of parsing and UI.
2. Set another source breakpoint at `acceptedDelegateEntryCount += 1`, plus `didInvalidateWith`, `stopSession`, and `session.run(config)`. A raw hit without acceptance narrows the path to parsing, scheduling, or the stale-session guard.
3. Optionally set a symbolic breakpoint on `-[NISession runWithConfiguration:]` and `-[NISession invalidate]` to inspect application call stacks. Prefer source breakpoints for the Swift delegate; do not assume a guessed mangled symbol is valid.
4. In macOS Console select the connected iPhone, start streaming, and filter subsystem `DLTDOAReceiver`, category `CallbackAudit` (or filter those strings in Xcode Console). Notice-level audit records explicitly expose only random per-session IDs, counts, booleans, lifecycle names, and error codes, never coordinates, addresses, packet values, or error userInfo.

## Reading the evidence

- `attach` includes stable random session identity, delegate identity equality, and the explicit serial delegate queue. `run requested` / `run returned` are requests, **not** proof of UWB reception.
- `raw didUpdateDLTDOA` is logged and counted synchronously at entry, before parsing, Task scheduling, active-session filtering, or packet-log settings. A lock protects lifetime raw count and identity lookup; published UI values remain MainActor-only. A watchdog also refreshes raw UI count when parsing/UI acceptance has not completed.
- Lifetime raw > accepted + stale can mean work is in flight or parsing/MainActor handling has not completed; inspect breakpoints/Console before concluding a failure. A stale record proves the current-session identity guard rejected the callback. These counters deliberately survive Clear Measurements; the older callback/empty/measurement counters reset with measurements.
- Raw stays zero with a verified attached/running session: no entry into this delegate implementation has been observed. It does **not** by itself identify entitlement, discovery, synchronization, radio, or framework cause. Solver output cannot explain a zero raw-entry count.
- Accepted > 0 but measurement count zero means empty callbacks, not no callback. Accepted measurements with no solution move investigation downstream to geometry/solver, without changing RF configuration.
- Existing `ContentView.onDisappear { manager.stopSession() }` can invalidate the DL-TDoA session when the view disappears, including possible tab navigation. This behavior is intentionally unchanged; keep the receiver view visible and correlate invalidate logs / stopSession call stacks before attributing silence to radio issues. No speculative lifecycle fix or automatic restart was added.

No simulated callback injection is used or presented as evidence of real reception.

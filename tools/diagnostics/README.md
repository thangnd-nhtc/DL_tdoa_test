# In-app diagnostics validation

The Diagnostics card exports a plain-text report through the iOS share sheet. Existing Copy Logs remains unchanged (visible 200-line buffer); the report keeps all app log lines in memory since launch or Clear Logs, including lifecycle transitions, with ISO timestamps. Packet logging remains throttled/optional. Counters explicitly distinguish lifetime delegate entries from the resettable measurement window. Reports include run identity, network ID, OS/model, support, authorization, lifecycle/current state and last callback time.

A snapshot is generated after 10 seconds without an accepted callback, once per start, and on NI invalidation. This threshold is app-observed silence, NOT proof of a nearbyd sync timeout. Snapshots are memory-only. A later invalidation replaces the snapshot. Sharing current report does not alter it. Review identifiers and imported raw content before sharing.

The app cannot read nearbyd system logs through public iOS APIs. Paste External nearbyd Log accepts user-supplied text only. Analysis counts matching lines and preserves first/last matching textual timestamps without claiming causal diagnosis, authenticity, or session correlation. Imported evidence is explicitly labelled and can be cleared independently.

## Pure Swift fixtures (no XCTest target exists)
On a Mac with Swift installed, concatenate `DLTDOAReceiver/NearbyLogAnalyzer.swift` followed by `tools/diagnostics/analyzer_fixtures.swift` into a temporary Swift script, then run `swift` on that script. Fixtures cover all five markers, duplicates, timestamp extraction, no markers, absent timestamps and case-insensitivity.

Windows environment used for implementation has no Swift/Xcode toolchain, so these fixtures and the iOS app have not been compiled/run here. Static checks confirm the analyzer is registered in Xcode Sources. Device validation remains required: start with no anchors, wait 10 seconds, open/share automatic snapshot; check current report and raw/accepted/stale counts; paste fixture and verify summary; clear imported evidence; clear logs; stop/start, and confirm session/network identity. Test normal callbacks, background/foreground, NI invalidation and share cancellation on device.

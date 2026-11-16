import Foundation

// Run on macOS: concatenate NearbyLogAnalyzer.swift and this file, then `swift combined.swift`.
let fixture = """
2026-11-16 02:00:01.123 Scanned OOB network=42
2026-11-16T02:00:02Z Built FiRa
02:00:03.456 sync timeout
02:00:04 coordinate x=1
02:00:05 stopped
02:00:06 Scanned OOB
unrelated line
"""
let result = NearbyLogAnalyzer.summary(fixture)
assert(result.contains("Scanned OOB: 2 matching lines"))
assert(result.contains("Built FiRa: 1 matching lines"))
assert(result.contains("Sync timeout: 1 matching lines"))
assert(result.contains("Coordinates: 1 matching lines"))
assert(result.contains("Stopped: 1 matching lines"))
assert(result.contains("first timestamp: 2026-11-16 02:00:01.123; last: 02:00:06"))
assert(NearbyLogAnalyzer.summary("").contains("Scanned OOB: 0 matching lines"))
assert(NearbyLogAnalyzer.summary("Scanned OOB").contains("first timestamp: not found"))
assert(NearbyLogAnalyzer.summary("SYNC TIMED OUT").contains("Sync timeout: 1 matching lines"))
print("NearbyLogAnalyzer fixtures passed")

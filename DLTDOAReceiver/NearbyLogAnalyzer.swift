import Foundation

/// Heuristic text matching only: no daemon access and no inferred session correlation.
enum NearbyLogAnalyzer {
    static func summary(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return "No meaningful log text supplied. Paste externally collected nearbyd log lines; whitespace or punctuation alone cannot be analyzed."
        }
        let lines = text.components(separatedBy: .newlines)
        let markers: [(String, [String])] = [
            ("Scanned OOB", ["scanned oob"]),
            ("Built FiRa", ["built fira"]),
            ("Sync timeout", ["sync timeout", "sync timed out", "synchronization timeout"]),
            ("Coordinates", ["coordinate"]),
            ("Stopped", ["stopped"])
        ]
        var output = ["IMPORTED nearbyd text — heuristic analysis",
                      "Not live system logs. Origin, completeness, and session association are unverified.",
                      "Counts are matching lines, not events. Missing markers do not prove a missing stage."]
        for (label, needles) in markers {
            let hits = lines.filter { line in needles.contains { line.lowercased().contains($0) } }
            let times = hits.compactMap(timestamp)
            output.append("\(label): \(hits.count) matching lines; first timestamp: \(times.first ?? "not found"); last: \(times.last ?? "not found")")
        }
        output.append("Timestamps are copied from first/last matching input lines, not sorted or correlated to the app session. Marker matches alone do not establish RF reception or root cause.")
        return output.joined(separator: "\n")
    }

    private static func timestamp(_ line: String) -> String? {
        // Preserve timezone/fraction when supplied; also accepts Console's time-only format.
        let pattern = #"(?:\d{4}-\d{2}-\d{2}[T ])?\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[range])
    }
}

import Foundation
import CoreMedia

struct SRTVTTSubtitleParser: SubtitleParser {
    func parse(url: URL) throws -> [SubtitleCue] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SubDubError.inputUnavailable
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.uppercased() == "WEBVTT" || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") {
                index += 1
                continue
            }

            var timingLine = line
            if !line.contains("-->") {
                index += 1
                guard index < lines.count else { break }
                timingLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let separator = timingLine.range(of: "-->") else {
                index += 1
                continue
            }

            let startText = timingLine[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let endWithSettings = timingLine[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            let endText = endWithSettings.split(separator: " ", maxSplits: 1).first.map(String.init) ?? endWithSettings
            guard let start = parseTime(startText), let end = parseTime(endText), end > start else {
                throw SubDubError.subtitleValidationFailed(L10n.tr("subdub.error.invalid_timestamp"))
            }

            index += 1
            var textLines: [String] = []
            while index < lines.count {
                let content = lines[index]
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                textLines.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
                index += 1
            }

            let cueText = textLines.joined(separator: "\n")
                .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else {
                throw SubDubError.subtitleValidationFailed(L10n.tr("subdub.error.empty_caption"))
            }
            cues.append(SubtitleCue(start: start, end: end, text: cueText))
            index += 1
        }

        guard !cues.isEmpty else { throw SubDubError.subtitleValidationFailed(L10n.tr("subdub.error.no_cues")) }
        return cues.sorted { $0.start < $1.start }
    }

    private func parseTime(_ value: String) -> CMTime? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count >= 2, let seconds = Double(parts.last ?? "") else { return nil }
        let minutesIndex = parts.count - 2
        guard let minutes = Double(parts[minutesIndex]) else { return nil }
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return CMTime(seconds: hours * 3600 + minutes * 60 + seconds, preferredTimescale: 1000)
    }
}

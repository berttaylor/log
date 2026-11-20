import AVFoundation
import Speech

/// One stretch of speech in a transcript, timed from the start of the recording.
struct Line: Equatable { let start: Double, end: Double, speaker: String, text: String }

/// Interleaves both sides by time. A "Me" line that repeats an overlapping "Them" line is the
/// other side leaking from the speakers into the mic, so it is dropped.
func merge(me: [Line], them: [Line]) -> [Line] {
    func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
    let mine = me.filter { m in
        let w = words(m.text)
        return !them.contains { t in
            t.start < m.end && m.start < t.end && Double(w.intersection(words(t.text)).count) >= 0.6 * Double(w.count)
        }
    }
    return (mine + them).sorted { $0.start < $1.start }
}

/// Markdown with one paragraph per turn: "**12:04 Them:** ...".
func markdown(_ lines: [Line], title: String) -> String {
    var out = "# \(title)", speaker = ""
    for line in lines {
        if line.speaker == speaker { out += " " + line.text; continue }
        speaker = line.speaker
        let s = Int(line.start)
        out += String(format: "\n\n**%d:%02d %@:** ", s / 60, s % 60, line.speaker) + line.text
    }
    return out + "\n"
}

/// Writes transcript.md from the separate tracks, on this Mac (macOS 26+). The separate
/// tracks say who spoke, so there is no guessing. macOS downloads the speech model once.
@available(macOS 26, *)
func transcribe(_ dir: URL) async throws {
    let tracks = dir.appendingPathComponent("tracks")
    async let me = speech(in: tracks.appendingPathComponent("me.m4a"), speaker: "Me")
    async let them = speech(in: tracks.appendingPathComponent("them.m4a"), speaker: "Them")
    let lines = merge(me: try await me, them: try await them)
    let meta = Meta.read(dir)
    let title = [meta?.app.map { "\($0) call" } ?? "Call", meta?.started.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: ", ")
    try markdown(lines, title: title).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    if var meta, !(meta.files ?? []).contains("transcript.md") {
        meta.files = ((meta.files ?? []) + ["transcript.md"]).sorted()
        try meta.write(dir)
    }
}

@available(macOS 26, *)
func speech(in url: URL, speaker: String) async throws -> [Line] {
    guard exists(url) else { return [] }
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await download.downloadAndInstall() }
    let lines = Task {
        try await transcriber.results.reduce(into: [Line]()) { lines, r in
            let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append(Line(start: r.range.start.seconds, end: r.range.end.seconds, speaker: speaker, text: text)) }
        }
    }
    try await SpeechAnalyzer(modules: [transcriber]).start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
    return try await lines.value
}

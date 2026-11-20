import AVFoundation
import Speech

/// One stretch of speech in a transcript, timed from the start of the recording.
struct Line: Equatable { let start: Double, end: Double, speaker: String, text: String }

/// Interleaves both sides by time. A "Me" line of 3 or more words that mostly repeats an
/// overlapping "Them" line is the other side leaking from the speakers into the mic, so it is
/// dropped. Shorter lines ("Yeah.") are kept: too little to tell an echo from a reply.
func merge(me: [Line], them: [Line]) -> [Line] {
    func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
    let theirs = them.map { ($0, words($0.text)) }
    let mine = me.filter { m in
        let w = words(m.text)
        return w.count < 3 || !theirs.contains { t, tw in
            t.start < m.end && m.start < t.end && Double(w.intersection(tw).count) >= 0.6 * Double(w.count)
        }
    }
    return (mine + them).sorted { $0.start < $1.start }
}

/// Markdown with one paragraph per turn, or after a pause of over 10 s: "**12:04 Them:** ...".
func markdown(_ lines: [Line], title: String) -> String {
    var out = "# \(title)", speaker = "", end = 0.0
    for line in lines {
        defer { end = line.end }
        let s = Int(line.start)
        if line.speaker.isEmpty {   // a mark from Mark This Moment
            out += String(format: "\n\n**⚑ %d:%02d marked**", s / 60, s % 60); speaker = ""; continue
        }
        if line.speaker == speaker, line.start - end <= 10 { out += " " + line.text; continue }
        speaker = line.speaker
        out += String(format: "\n\n**%d:%02d %@:** ", s / 60, s % 60, line.speaker) + line.text
    }
    return out + "\n"
}

/// Writes transcript.md from the separate tracks, on this Mac (macOS 26+). The separate
/// tracks say who spoke, so there is no guessing. macOS downloads the speech model once.
@available(macOS 26, *)
func transcribe(_ dir: URL) async throws {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Speech recognition doesn't support \(Locale.current.identifier)."])
    }
    let model = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    if let download = try await AssetInventory.assetInstallationRequest(supporting: [model]) { try await download.downloadAndInstall() }
    let tracks = dir.appendingPathComponent("tracks")
    async let me = speech(in: tracks.appendingPathComponent("me.m4a"), speaker: "Me", locale: locale)
    async let them = speech(in: tracks.appendingPathComponent("them.m4a"), speaker: "Them", locale: locale)
    let meta = Meta.read(dir)
    let marks = (meta?.marks ?? []).map { Line(start: $0, end: $0, speaker: "", text: "") }
    let lines = (merge(me: await me, them: await them) + marks).sorted { $0.start < $1.start }
    var title = meta?.app.map { "\($0) call" } ?? "Call"
    if let started = meta?.started { title += ", " + started.formatted(date: .abbreviated, time: .shortened) }
    try markdown(lines, title: title).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    if var meta, !(meta.files ?? []).contains("transcript.md") {
        meta.files = ((meta.files ?? []) + ["transcript.md"]).sorted()
        try meta.write(dir)
    }
}

/// One track's speech, or nothing if the track is missing or unreadable.
@available(macOS 26, *)
func speech(in url: URL, speaker: String, locale: Locale) async -> [Line] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    let lines = Task {   // keeps what arrived if the stream fails part-way
        var lines: [Line] = []
        do {
            for try await r in transcriber.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { lines.append(Line(start: r.range.start.seconds, end: r.range.end.seconds, speaker: speaker, text: text)) }
            }
        } catch {}
        return lines
    }
    defer { lines.cancel() }
    let analyzer = SpeechAnalyzer(modules: [transcriber])   // must live until the results end
    do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) } catch { return [] }
    let result = await lines.value
    withExtendedLifetime(analyzer) {}
    return result
}

/// Saved recordings without a transcript, for example because Log quit while writing it.
func untranscribed() -> [URL] {
    let unfinished = Set(interruptedRecordings())
    return recordings(test: false).filter { !exists($0.appendingPathComponent("transcript.md")) && !unfinished.contains($0) }
}

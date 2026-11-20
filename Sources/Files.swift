import AVFoundation

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func aac(rate: Double, channels: AVAudioChannelCount) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
     AVEncoderBitRateKey: 64_000 * Int(channels)]
}

/// Turns a recording's raw tracks (me.caf, them.caf) into the files people keep: me.m4a,
/// them.m4a and call.m4a. Runs at stop, and again on launch for a recording Log was killed
/// in the middle of. The raw tracks are deleted last, so an interrupted run can be repeated.
func finish(_ dir: URL) throws {
    let me = dir.appendingPathComponent("me.caf"), them = dir.appendingPathComponent("them.caf")
    if exists(me), exists(them) { try mix(me, them, to: dir.appendingPathComponent("call.m4a")) }
    for raw in [me, them] where exists(raw) {
        try encode(raw, to: raw.deletingPathExtension().appendingPathExtension("m4a"))
        try FileManager.default.removeItem(at: raw)
    }
}

/// Finishes every recording that still has raw tracks, oldest first, and returns them.
func recoverInterrupted() -> [URL] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
    let interrupted = dirs.filter { exists($0.appendingPathComponent("me.caf")) || exists($0.appendingPathComponent("them.caf")) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for dir in interrupted { try? finish(dir) }
    return interrupted
}

/// Re-encodes an audio file as AAC in .m4a.
func encode(_ src: URL, to dst: URL) throws {
    let input = try AVAudioFile(forReading: src)
    let output = try AVAudioFile(forWriting: dst, settings: aac(rate: input.fileFormat.sampleRate, channels: input.fileFormat.channelCount))
    let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 48_000)!
    while input.framePosition < input.length {
        try input.read(into: buf)
        try output.write(from: buf)
    }
}

/// Puts two mono tracks side by side in one stereo file: first on the left, second on the right.
/// Both come from the same capture stream, so they share a sample rate.
func mix(_ left: URL, _ right: URL, to out: URL) throws {
    let files = try [left, right].map(AVAudioFile.init(forReading:))
    let rate = files[0].processingFormat.sampleRate
    // ponytail: no resampling; if the rates ever differ, call.m4a is skipped (me/them still saved).
    guard files[1].processingFormat.sampleRate == rate else { return }
    let output = try AVAudioFile(forWriting: out, settings: aac(rate: rate, channels: 2))
    let chunk: AVAudioFrameCount = 48_000
    let inputs = files.map { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk)! }
    let stereo = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: chunk)!
    while true {
        for (file, buf) in zip(files, inputs) { buf.frameLength = 0; try? file.read(into: buf) }
        stereo.frameLength = inputs.map(\.frameLength).max()!
        guard stereo.frameLength > 0 else { return }
        for (channel, buf) in inputs.enumerated() {   // the shorter track ends in silence
            let dst = stereo.floatChannelData![channel]
            dst.update(repeating: 0, count: Int(chunk))
            dst.update(from: buf.floatChannelData![0], count: Int(buf.frameLength))
        }
        try output.write(from: stereo)
    }
}

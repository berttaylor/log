import Accelerate
import AVFoundation

// A recording's folder:
//   Call.mp4      every screen side by side with the call audio (Call.m4a when audio only)
//   meta.json     when it started, how long it ran, which mic, which files
//   tracks/       me.m4a, them.m4a and screen-N.mov: the separate sources, for agents and editing
// While recording, tracks/ holds raw me.caf and them.caf, which survive a crash.

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func aac(rate: Double, channels: AVAudioChannelCount) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
     AVEncoderBitRateKey: 64_000 * Int(channels)]
}

struct Meta: Codable {
    var started: Date
    var app: String?
    var microphone: String?
    var duration: Double?
    var files: [String]?

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent("meta.json") }
    static func read(_ dir: URL) -> Meta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(dir))).flatMap { try? decoder.decode(Meta.self, from: $0) }
    }
    func write(_ dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Meta.url(dir), options: .atomic)
    }
}

/// Turns a recording's raw tracks into the finished files. Runs at stop, and again on launch
/// for a recording Log was killed in the middle of. Every step rebuilds from the raw tracks,
/// which are deleted last, so an interrupted run can simply be repeated.
func finish(_ dir: URL) async throws {
    let tracks = dir.appendingPathComponent("tracks")
    let raw = ["me.caf", "them.caf"].map(tracks.appendingPathComponent).filter(exists)
    for file in raw { try encode(file, to: file.deletingPathExtension().appendingPathExtension("m4a")) }
    let call = dir.appendingPathComponent("Call.m4a"), video = dir.appendingPathComponent("Call.mp4")
    if !raw.isEmpty { try mix(raw, to: call) }
    let screens = (try FileManager.default.contentsOfDirectory(at: tracks, includingPropertiesForKeys: nil))
        .filter { $0.pathExtension == "mov" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    if !screens.isEmpty, exists(call), try await composite(screens: screens, audio: call, to: video) {
        try FileManager.default.removeItem(at: call)
    }
    var meta = Meta.read(dir) ?? Meta(started: (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
    let main = [video, call].first(where: exists)
    if let main { meta.duration = try await AVURLAsset(url: main).load(.duration).seconds.rounded() }
    meta.files = FileManager.default.subpaths(atPath: dir.path)?
        .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".caf") && $0 != "tracks" && $0 != "meta.json" }.sorted()
    try meta.write(dir)
    for file in raw { try FileManager.default.removeItem(at: file) }
}

/// Recordings Log was killed in the middle of: they still have raw tracks. Oldest first.
func interruptedRecordings() -> [URL] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
    return dirs.filter { dir in ["me.caf", "them.caf"].contains { exists(dir.appendingPathComponent("tracks/" + $0)) } }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Re-encodes an audio file as AAC in .m4a.
func encode(_ src: URL, to dst: URL) throws {
    let input = try AVAudioFile(forReading: src)
    let output = try AVAudioFile(forWriting: dst, settings: aac(rate: input.fileFormat.sampleRate, channels: input.fileFormat.channelCount))
    let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 48_000)!
    while input.framePosition < input.length {   // the empty-read guard stops a crashed file whose header over-promises
        try input.read(into: buf)
        guard buf.frameLength > 0 else { return }
        try output.write(from: buf)
    }
}

/// Mixes mono tracks into one, so every voice is in both ears. The tracks come from the same
/// capture stream, so they share a sample rate.
func mix(_ inputs: [URL], to out: URL) throws {
    let files = try inputs.map(AVAudioFile.init(forReading:))
    let format = files[0].processingFormat
    guard files.allSatisfy({ $0.processingFormat.sampleRate == format.sampleRate }) else { throw CocoaError(.fileReadCorruptFile) }
    let output = try AVAudioFile(forWriting: out, settings: aac(rate: format.sampleRate, channels: 1))
    let chunk: AVAudioFrameCount = 48_000
    let buffers = files.map { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk)! }
    let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
    while true {
        for (file, buf) in zip(files, buffers) {
            buf.frameLength = 0
            if file.framePosition < file.length { try? file.read(into: buf) }
        }
        sum.frameLength = buffers.map(\.frameLength).max()!
        guard sum.frameLength > 0 else { return }
        let dst = sum.floatChannelData![0]
        dst.update(repeating: 0, count: Int(chunk))
        for buf in buffers {   // a shorter track just stops adding
            vDSP_vadd(dst, 1, buf.floatChannelData![0], 1, dst, 1, vDSP_Length(buf.frameLength))
        }
        var low: Float = -1, high: Float = 1
        vDSP_vclip(dst, 1, &low, &high, dst, 1, vDSP_Length(sum.frameLength))
        try output.write(from: sum)
    }
}

/// Puts every screen side by side, at native size and top-aligned, in one video with the call
/// audio, so nothing is cropped or hidden. The row is scaled down only past 8192 pixels wide,
/// the HEVC limit. Frames stay at one a second. Unreadable screens are left out; returns false
/// if none could be read.
func composite(screens: [URL], audio: URL, to out: URL) async throws -> Bool {
    let comp = AVMutableComposition()
    let assets = screens.map { AVURLAsset(url: $0) }, audioAsset = AVURLAsset(url: audio)   // must outlive the export
    var placed: [(AVMutableCompositionTrack, CGFloat)] = []
    var width: CGFloat = 0, height: CGFloat = 0
    for asset in assets {
        guard let src = try? await asset.loadTracks(withMediaType: .video).first,
              let (range, size) = try? await src.load(.timeRange, .naturalSize), size.width > 0,
              let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        do { try track.insertTimeRange(range, of: src, at: range.start) } catch { comp.removeTrack(track); continue }
        placed.append((track, width))
        width += size.width; height = max(height, size.height)
    }
    if let src = try await audioAsset.loadTracks(withMediaType: .audio).first,
       let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try track.insertTimeRange(try await src.load(.timeRange), of: src, at: .zero)
    }
    guard !placed.isEmpty else { return false }
    let scale = min(1, 8192 / width)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
    instruction.layerInstructions = placed.map { track, x in
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: x, y: 0), at: .zero)
        return layer
    }
    let video = AVMutableVideoComposition()
    video.instructions = [instruction]
    video.frameDuration = CMTime(value: 1, timescale: 1)
    video.renderSize = CGSize(width: Int(width * scale) & ~1, height: Int(height * scale) & ~1)
    guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality) else {
        throw CocoaError(.featureUnsupported)
    }
    export.videoComposition = video
    try? FileManager.default.removeItem(at: out)   // a repeated, interrupted run may have left one
    try await export.export(to: out, as: .mp4)
    return true
}

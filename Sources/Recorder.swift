import Accelerate
import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Capture timestamps use the host clock.
func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

/// Captures one call: what the Mac plays ("them"), the microphone ("me") and, optionally,
/// every display. All files share one time zero, the moment recording started.
/// Shared state is touched only on `q` (audio) or each writer's own queue (screens).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let dir: URL, screens: Bool
    let me: Track, them: Track
    var onError: ((Error) -> Void)?
    private let q = DispatchQueue(label: "log.audio")
    private var start = CMTime.zero
    private var audio: SCStream?
    private var screenStreams: [(SCStream, ScreenWriter)] = []

    init(dir: URL, screens: Bool) {
        self.dir = dir; self.screens = screens
        let tracks = dir.appendingPathComponent("tracks")
        me = Track(tracks.appendingPathComponent("me.caf")); them = Track(tracks.appendingPathComponent("them.caf"))
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        let content = try await SCShareableContent.current
        guard let main = content.displays.first else { throw CocoaError(.featureUnsupported) }
        start = hostNow()
        // ScreenCaptureKit needs a display to capture audio, so ask for a tiny 2x2 picture and ignore it.
        let cfg = SCStreamConfiguration()
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        cfg.captureMicrophone = true
        // Prefer the built-in mic: recording from AirPods drops them into low-quality call mode,
        // which would spoil what you hear. Macs without one use the default mic.
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let mic = mics.first { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn } ?? AVCaptureDevice.default(for: .audio)
        cfg.microphoneCaptureDeviceID = mic?.uniqueID
        try Meta(started: Date(), microphone: mic?.localizedName).write(dir)
        let s = SCStream(filter: SCContentFilter(display: main, excludingWindows: []), configuration: cfg, delegate: self)
        for type in [SCStreamOutputType.screen, .audio, .microphone] { try s.addStreamOutput(self, type: type, sampleHandlerQueue: q) }
        try await s.startCapture()
        audio = s

        guard screens else { return }
        for (i, d) in content.displays.enumerated() {
            // Native pixels, capped at 2560 wide: text stays readable and files stay small.
            let mode = CGDisplayCopyDisplayMode(d.displayID)
            let w = Double(mode?.pixelWidth ?? d.width), h = Double(mode?.pixelHeight ?? d.height)
            let scale = min(1, 2560 / w)
            let c = SCStreamConfiguration()
            c.width = Int(w * scale) & ~1; c.height = Int(h * scale) & ~1   // H.264 needs even sizes
            c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let writer = try ScreenWriter(url: dir.appendingPathComponent("tracks/screen-\(i + 1).mov"),
                                          width: c.width, height: c.height, start: start)
            let vs = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: c, delegate: nil)
            try vs.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            screenStreams.append((vs, writer))   // before starting, so stop() can always finish it
            try await vs.startCapture()
        }
    }

    /// Stops capture, closes every file and turns the raw tracks into the finished files.
    /// Safe to call on a recorder that only partly started. Throws if a file couldn't be saved.
    func stop() async throws {
        let end = hostNow()
        try? await audio?.stopCapture()
        var failed: Error?
        for (vs, writer) in screenStreams {
            try? await vs.stopCapture()
            if let error = await writer.finish(at: end) { failed = error }
        }
        q.sync { me.file = nil; them.file = nil }   // closes the raw audio files
        try await finish(dir)
        if let failed { throw failed }
    }

    var elapsed: Double { (hostNow() - start).seconds }

    /// Sides of the call with no sound at all so far: a muted mic, or call audio going
    /// somewhere Log can't hear.
    func silentSides() -> [String] {
        q.sync { [("your microphone", me.heard), ("the other side", them.heard)] }.filter { !$0.1 }.map(\.0)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, type != .screen else { return }
        (type == .audio ? them : me).write(sb, start: start)
    }

    func stream(_ s: SCStream, didStopWithError error: Error) { onError?(error) }
}

/// One side of the call, written as 16-bit PCM in a CAF file. Unlike AAC in .m4a, a CAF file
/// stays readable if Log is killed mid-call. Gaps are padded with silence so every track
/// lines up with the shared start time.
final class Track {
    let url: URL
    var file: AVAudioFile?
    var written: AVAudioFramePosition = 0
    /// Whether any buffer so far had sound in it.
    var heard = false
    init(_ url: URL) { self.url = url }

    func write(_ sb: CMSampleBuffer, start: CMTime) {
        guard var asbd = sb.formatDescription?.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        try? sb.withAudioBufferList { abl, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer) else { return }
            if file == nil {
                let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                          AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 16]
                file = try? AVAudioFile(forWriting: url, settings: pcm, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            }
            guard let file else { return }
            var gap = AVAudioFramePosition((sb.presentationTimeStamp - start).seconds * fmt.sampleRate) - written
            while gap > AVAudioFramePosition(fmt.sampleRate / 20) {   // ignore jitter under 50 ms
                let n = AVAudioFrameCount(min(gap, 48_000))
                guard let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { break }
                silence.frameLength = n   // new buffers are zero-filled
                try? file.write(from: silence)
                written += AVAudioFramePosition(n); gap -= AVAudioFramePosition(n)
            }
            try? file.write(from: buf)
            written += AVAudioFramePosition(buf.frameLength)
            if !heard, let samples = buf.floatChannelData?[0], buf.frameLength > 0 {
                var peak: Float = 0
                vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buf.frameLength))
                // -80 dBFS: below any working mic's noise floor, above the exact zeros of no playback
                if peak > 1e-4 { heard = true }
            }
        }
    }
}

/// One display, written to a QuickTime movie in 5-second fragments, so the file still plays
/// if Log is killed mid-call.
final class ScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "log.screen")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(url: URL, width: Int, height: Int, start: CMTime) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: start)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // ScreenCaptureKit also sends "nothing changed" frames without an image: skip those.
        let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        guard sb.isValid, let status = info?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    /// Ends the movie at `end`, so a screen that stopped changing still lasts the whole call.
    /// Returns the writer's error if the movie couldn't be written.
    func finish(at end: CMTime) async -> Error? {
        guard writer.status == .writing else { return writer.error }
        queue.sync {
            input.markAsFinished()
            writer.endSession(atSourceTime: end)
        }
        await writer.finishWriting()
        return writer.error
    }
}

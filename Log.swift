// Log: a macOS menu bar app that records both sides of a call. It saves what your Mac plays
// and what your microphone hears as aligned tracks, plus, optionally, every screen at
// one frame a second.
//
// Files go to ~/Downloads/Log/<date-time>/: me.m4a, them.m4a, call.m4a (you left, them right)
// and screen-1.mp4, screen-2.mp4, ... when screens are on.
//
// Build: ./build.sh    Test from a terminal: build/Log.app/Contents/MacOS/Log --test <seconds> [screens]
import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit
import ServiceManagement

func aac(rate: Double, channels: AVAudioChannelCount) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
     AVEncoderBitRateKey: 64_000 * Int(channels)]
}

/// One side of the call, written as AAC. Gaps are padded with silence so every track
/// lines up with the shared start time.
final class Track {
    let url: URL
    var file: AVAudioFile?
    var written: AVAudioFramePosition = 0
    init(_ url: URL) { self.url = url }

    func write(_ sb: CMSampleBuffer, start: CMTime) {
        guard var asbd = sb.formatDescription?.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        try? sb.withAudioBufferList { abl, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer) else { return }
            if file == nil {
                file = try? AVAudioFile(forWriting: url, settings: aac(rate: fmt.sampleRate, channels: fmt.channelCount),
                                        commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
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
        }
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

/// Shared state is touched only on `q` (audio) or under `lock` (screen files).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    let dir: URL, screens: Bool
    let me: Track, them: Track
    var onError: ((Error) -> Void)?
    private let q = DispatchQueue(label: "log.audio")
    private var start: CMTime?
    private var audio: SCStream?
    private var screenStreams: [(SCStream, SCRecordingOutput)] = []
    private var unfinished = Set<ObjectIdentifier>()
    private var allFinished: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(dir: URL, screens: Bool) {
        self.dir = dir; self.screens = screens
        me = Track(dir.appendingPathComponent("me.m4a")); them = Track(dir.appendingPathComponent("them.m4a"))
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.current
        guard let main = content.displays.first else { throw CocoaError(.featureUnsupported) }
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
        if let mic = mics.first(where: { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn }) {
            cfg.microphoneCaptureDeviceID = mic.uniqueID
        }
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
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = dir.appendingPathComponent("screen-\(i + 1).mp4")
            rc.outputFileType = .mp4
            rc.videoCodecType = .h264
            let out = SCRecordingOutput(configuration: rc, delegate: self)
            let vs = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: c, delegate: nil)
            try vs.addRecordingOutput(out)
            try await vs.startCapture()
            screenStreams.append((vs, out))
        }
    }

    /// Stops everything, waits for the files to be written, then makes call.m4a. Safe to call
    /// on a recorder that only partly started.
    func stop() async {
        try? await audio?.stopCapture()
        if !screenStreams.isEmpty {   // ask every screen file to finish, then wait for all of them
            await withCheckedContinuation { c in
                lock.withLock { unfinished = Set(screenStreams.map { ObjectIdentifier($0.1) }); allFinished = c }
                for (vs, out) in screenStreams {
                    do { try vs.removeRecordingOutput(out) } catch { finished(ObjectIdentifier(out)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { self.finished(nil) }   // never hang on a stuck file
            }
            for (vs, _) in screenStreams { try? await vs.stopCapture() }
        }
        q.sync { me.file = nil; them.file = nil }   // closes and finalises the audio files
        try? mix(me.url, them.url, to: dir.appendingPathComponent("call.m4a"))
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, type != .screen else { return }
        let t0 = start ?? sb.presentationTimeStamp
        start = t0
        (type == .audio ? them : me).write(sb, start: t0)
    }

    func stream(_ s: SCStream, didStopWithError error: Error) { onError?(error) }
    func recordingOutputDidFinishRecording(_ out: SCRecordingOutput) { finished(ObjectIdentifier(out)) }
    func recordingOutput(_ out: SCRecordingOutput, didFailWithError error: Error) { finished(ObjectIdentifier(out)) }
    /// Called once per finished screen file, or with nil when time is up. Resumes `stop` once.
    private func finished(_ id: ObjectIdentifier?) {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let id { unfinished.remove(id) }
            guard id == nil || unfinished.isEmpty else { return nil }
            defer { allFinished = nil }
            return allFinished
        }?.resume()
    }
}

/// Free space macOS can make available (includes purgeable space).
func freeGB() -> Double {
    let v = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1e9 } ?? .infinity
}
let minFreeGB = 5.0
let library = URL.downloadsDirectory.appendingPathComponent("Log")

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, starting, recording, saving }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let icons = (idle: logIcon(filled: false), recording: logIcon(filled: true))
    let defaults = UserDefaults.standard
    var state = State.idle
    var endsAt = Date.distantPast
    var rec: Recorder?
    var saving: Task<Void, Never>?
    var ticker: Timer?
    var last: URL?
    var warning: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        if !defaults.bool(forKey: "loginSet") {   // first launch: open at login (switch off in the menu)
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginSet")
        }
        item.menu = NSMenu()
        item.menu?.delegate = self
        item.button?.imagePosition = .imageLeading
        update()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop()   // quitting, logging out or shutting down mid-call still saves the files
        guard let saving else { return .terminateNow }
        Task { await saving.value; sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    var timeLeft: String? {
        guard state == .recording else { return nil }
        let s = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
        return String(format: "%d:%02d", s / 3600, s % 3600 / 60)
    }

    /// The menu bar shows only the icon (filled while recording), so it gives nothing away on a
    /// shared screen. The countdown is opt-in.
    func update() {
        guard let button = item.button else { return }
        let left = timeLeft
        button.image = left == nil ? icons.idle : icons.recording
        button.appearsDisabled = state == .saving
        if let left { button.title = defaults.bool(forKey: "showTimer") ? " \(left)" : "" }
        else { button.title = warning == nil ? "" : " ⚠︎" }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, key: String = "", on: Bool? = nil, tag: Int = 0, target: AnyObject? = nil) {
            let m = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            m.target = target ?? self; m.tag = tag
            if let on { m.state = on ? .on : .off }
        }
        switch state {
        case .idle:
            if let warning { add(warning); menu.addItem(.separator()) }
            for (title, mins) in [("30 minutes", 30), ("1 hour", 60), ("1½ hours", 90), ("2 hours", 120), ("2½ hours", 150)] {
                add("Record \(title)", #selector(record), tag: mins)
            }
        case .starting: add("Starting…")
        case .recording:
            add("Recording \(rec?.screens == true ? "audio and screens" : "audio") · \(timeLeft ?? "") left")
            add("Stop now", #selector(stopNow), key: "s")
        case .saving: add("Saving…")
        }
        menu.addItem(.separator())
        add("Show Recordings", #selector(showRecordings))
        add("Capture Screens (1 frame a second)", state == .idle ? #selector(toggleScreens) : nil,
            on: defaults.bool(forKey: "captureScreens"))
        add("Show Timer in Menu Bar", #selector(toggleTimer), on: defaults.bool(forKey: "showTimer"))
        add("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Quit Log", #selector(NSApplication.terminate), key: "q", target: NSApp)
    }

    @objc func record(_ sender: NSMenuItem) {
        let free = freeGB()
        guard free >= minFreeGB else {
            return alert("Not enough disk space to record",
                         String(format: "Only %.1f GB free. Log needs at least %.0f GB. Free some space and try again.", free, minFreeGB))
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let r = Recorder(dir: library.appendingPathComponent(f.string(from: Date())), screens: defaults.bool(forKey: "captureScreens"))
        r.onError = { error in Task { @MainActor in self.stop(warning: "Stopped early: \(error.localizedDescription)") } }
        let minutes = sender.tag
        rec = r; state = .starting; warning = nil; update()
        Task {
            do {
                try await r.start()
                endsAt = Date(timeIntervalSinceNow: Double(minutes) * 60)
                state = .recording
                ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { @MainActor in self.tick() } }
            } catch {
                await r.stop()
                try? FileManager.default.removeItem(at: r.dir)
                rec = nil; state = .idle
                alert("Couldn't start recording", """
                    Allow Log in System Settings > Privacy & Security, under both Microphone and \
                    Screen & System Audio Recording, then try again.

                    \(error.localizedDescription)
                    """)
            }
            update()
        }
    }

    func tick() {
        if endsAt.timeIntervalSinceNow <= 0 { stop() }
        // No pop-up mid-call (it could appear on a shared screen): stop and flag it in the menu.
        else if freeGB() < minFreeGB { stop(warning: String(format: "Stopped early: less than %.0f GB of disk left", minFreeGB)) }
        else { update() }
    }

    @objc func stopNow() { stop() }

    func stop(warning: String? = nil) {
        guard state == .recording, let r = rec else { return }
        state = .saving; self.warning = warning
        ticker?.invalidate()
        update()
        saving = Task {
            await r.stop()
            rec = nil; last = r.dir; saving = nil; state = .idle
            update()
        }
    }

    @objc func showRecordings() {
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([last ?? library])
    }

    @objc func toggleScreens() { defaults.set(!defaults.bool(forKey: "captureScreens"), forKey: "captureScreens") }

    @objc func toggleTimer() { defaults.set(!defaults.bool(forKey: "showTimer"), forKey: "showTimer"); update() }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate()   // a menu bar app's alert would otherwise open behind other windows
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.runModal()
    }
}

/// The menu bar icon: a log on its side, end grain facing out, like the app icon. A template
/// image, so macOS tints it for light and dark menu bars.
func logIcon(filled: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
        func stroke(_ path: NSBezierPath, _ width: CGFloat = 1.5) { path.lineWidth = width; path.stroke() }
        let face = NSRect(x: 11.5, y: 2, width: 7, height: 12), back = face.offsetBy(dx: -9, dy: 0)
        let bark = NSBezierPath()
        bark.move(to: NSPoint(x: face.midX, y: face.maxY)); bark.line(to: NSPoint(x: back.midX, y: back.maxY))
        bark.move(to: NSPoint(x: face.midX, y: face.minY)); bark.line(to: NSPoint(x: back.midX, y: back.minY))
        stroke(bark)
        stroke(NSBezierPath(ovalIn: face))
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: back.midX, height: 16).clip()   // only the far end's outer half shows
        stroke(NSBezierPath(ovalIn: back))
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: face.insetBy(dx: 1.9, dy: 3.2))
        if filled { ring.fill() } else { stroke(ring, 1.1) }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = filled ? "Log, recording" : "Log"
    return image
}

/// Terminal test: records to ~/Downloads/Log/test, stops, prints the folder.
func test(seconds: Double, screens: Bool) {
    let r = Recorder(dir: library.appendingPathComponent("test"), screens: screens)
    try? FileManager.default.removeItem(at: r.dir)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 30) { print("timed out"); exit(2) }
    Task {
        do { try await r.start() } catch { print("start failed: \(error)"); exit(1) }
        try await Task.sleep(for: .seconds(seconds))
        await r.stop()
        print(r.dir.path)
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared   // ScreenCaptureKit needs this, even in test mode
    app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    let delegate = args.count > 2 && args[1] == "--test" ? nil : App()
    if let delegate { app.delegate = delegate } else { test(seconds: Double(args[2]) ?? 5, screens: args.contains("screens")) }
    withExtendedLifetime(delegate) { app.run() }
}

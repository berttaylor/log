// Call Log: menu bar app. Records the call audio (whatever the Mac plays, on any
// output device) and the MacBook's built-in mic, as aligned tracks, for a set time.
// Optional: every screen at 1 frame a second (screen-1.mp4, screen-2.mp4, ...).
// Files: ~/Downloads/call-<date>/ (me.m4a, them.m4a, call.m4a with you left, them right).
// Build: ./build-call-log.sh. Test from a terminal: CallLog --test <seconds> [screens]
import AppKit
import AVFoundation
import ScreenCaptureKit
import ServiceManagement

final class Track {
    let url: URL
    var file: AVAudioFile?
    var written: AVAudioFramePosition = 0
    init(_ url: URL) { self.url = url }

    func write(_ sb: CMSampleBuffer, t0: CMTime) {
        guard let fd = sb.formatDescription, var asbd = fd.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        try? sb.withAudioBufferList { abl, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer) else { return }
            if file == nil {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate,
                                               AVNumberOfChannelsKey: fmt.channelCount, AVEncoderBitRateKey: 96000]
                file = try? AVAudioFile(forWriting: url, settings: settings,
                                        commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            }
            guard let file else { return }
            // Pad silence so both tracks stay aligned to the shared start time.
            let due = AVAudioFramePosition((sb.presentationTimeStamp - t0).seconds * fmt.sampleRate)
            var gap = due - written
            while gap > AVAudioFramePosition(fmt.sampleRate / 20) {
                let n = AVAudioFrameCount(min(gap, 48000))
                guard let pad = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { break }
                pad.frameLength = n
                for b in UnsafeMutableAudioBufferListPointer(pad.mutableAudioBufferList) {
                    if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
                }
                try? file.write(from: pad); written += AVAudioFramePosition(n); gap -= AVAudioFramePosition(n)
            }
            try? file.write(from: buf); written += AVAudioFramePosition(buf.frameLength)
        }
    }
}

final class Recorder: NSObject, SCStreamOutput, SCRecordingOutputDelegate {
    let dir: URL, them: Track, me: Track
    var screens = false
    var screenStreams: [(SCStream, SCRecordingOutput)] = []
    var finished: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    let lock = NSLock()

    func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) { resume(o) }
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError e: Error) { resume(o) }
    func resume(_ o: SCRecordingOutput) {
        lock.lock(); let c = finished.removeValue(forKey: ObjectIdentifier(o)); lock.unlock()
        c?.resume()
    }
    let q = DispatchQueue(label: "rec")
    var t0: CMTime?
    var stream: SCStream?
    init(dir: URL) {
        self.dir = dir
        them = Track(dir.appendingPathComponent("them.m4a")); me = Track(dir.appendingPathComponent("me.m4a"))
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, type != .screen else { return }
        if t0 == nil { t0 = sb.presentationTimeStamp }
        if type == .audio { them.write(sb, t0: t0!) } else if type == .microphone { me.write(sb, t0: t0!) }
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw NSError(domain: "No display found", code: 1) }
        let cfg = SCStreamConfiguration()
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.captureMicrophone = true
        // Always the built-in mic, even when AirPods are connected.
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if let mic = mics.first(where: { $0.localizedName.contains("MacBook") }) { cfg.microphoneCaptureDeviceID = mic.uniqueID }
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        if screens {
            for (i, d) in content.displays.enumerated() {
                // Full pixel size, capped at 2560 wide so text stays readable and files small.
                let mode = CGDisplayCopyDisplayMode(d.displayID)
                let pw = mode?.pixelWidth ?? d.width, ph = mode?.pixelHeight ?? d.height
                let k = min(1.0, 2560.0 / Double(pw))
                let c = SCStreamConfiguration()
                c.width = Int(Double(pw) * k) & ~1; c.height = Int(Double(ph) * k) & ~1
                c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                c.showsCursor = true
                let vs = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: c, delegate: nil)
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = dir.appendingPathComponent("screen-\(i + 1).mp4")
                rc.outputFileType = .mp4
                rc.videoCodecType = .h264
                let ro = SCRecordingOutput(configuration: rc, delegate: self)
                try vs.addRecordingOutput(ro)
                try await vs.startCapture()
                screenStreams.append((vs, ro))
            }
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        // Remove each recording output and wait until its file is fully written (max 10 s).
        for (vs, ro) in screenStreams {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); finished[ObjectIdentifier(ro)] = c; lock.unlock()
                do { try vs.removeRecordingOutput(ro) } catch { resume(ro) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { self.resume(ro) }
            }
            try? await vs.stopCapture()
        }
        q.sync { them.file = nil; me.file = nil }   // closes the files
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-loglevel", "error", "-y", "-i", me.url.path, "-i", them.url.path,
                       "-filter_complex", "[0:a][1:a]amerge=inputs=2[a]", "-map", "[a]", "-c:a", "aac", "-b:a", "128k",
                       dir.appendingPathComponent("call.m4a").path]
        try? p.run(); p.waitUntilExit()
    }
}

// Free space macOS will make available for important files (includes purgeable space).
func freeGB() -> Double {
    let v = try? FileManager.default.homeDirectoryForCurrentUser
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
}
let minFreeGB = 5.0

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var rec: Recorder?
    var endsAt: Date?
    var ticker: Timer?
    var last: URL?
    var warning: String?

    var captureScreens: Bool {
        get { UserDefaults.standard.bool(forKey: "captureScreens") }
        set { UserDefaults.standard.set(newValue, forKey: "captureScreens") }
    }

    var showTimer: Bool {
        get { UserDefaults.standard.bool(forKey: "showTimer") }
        set { UserDefaults.standard.set(newValue, forKey: "showTimer") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // First launch: open at login (can be switched off in the menu).
        if !UserDefaults.standard.bool(forKey: "loginSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSet")
        }
        refresh()
    }

    func refresh() {
        let menu = NSMenu()
        if let endsAt {
            let left = max(0, Int(endsAt.timeIntervalSinceNow))
            let time = String(format: "%d:%02d", left / 3600, (left % 3600) / 60)
            item.button?.title = showTimer ? "● \(time)" : "●"
            menu.addItem(withTitle: "Recording\(rec?.screens == true ? " audio + screens" : " audio") · stops in \(time)", action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem(title: "Stop now", action: #selector(stopNow), keyEquivalent: "s"))
        } else {
            item.button?.title = warning == nil ? "◎" : "◎ ⚠︎"
            if let warning { menu.addItem(withTitle: warning, action: nil, keyEquivalent: ""); menu.addItem(.separator()) }
            for (title, mins) in [("Record 30 minutes", 30), ("Record 1 hour", 60), ("Record 1½ hours", 90), ("Record 2 hours", 120), ("Record 2½ hours", 150)] {
                let m = NSMenuItem(title: title, action: #selector(record(_:)), keyEquivalent: "")
                m.tag = mins; menu.addItem(m)
            }
        }
        menu.addItem(.separator())
        if let last { let m = NSMenuItem(title: "Show last recording", action: #selector(showLast), keyEquivalent: ""); m.representedObject = last; menu.addItem(m) }
        let cs = NSMenuItem(title: "Also capture screens (1 per second)", action: #selector(toggleScreens), keyEquivalent: "")
        cs.state = captureScreens ? .on : .off
        if rec != nil { cs.action = nil }   // fixed while recording
        menu.addItem(cs)
        let st = NSMenuItem(title: "Show timer in menu bar", action: #selector(toggleTimer), keyEquivalent: "")
        st.state = showTimer ? .on : .off; menu.addItem(st)
        let li = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        li.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(li)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc func record(_ sender: NSMenuItem) {
        warning = nil
        let free = freeGB()
        if free < minFreeGB {
            let a = NSAlert()
            a.messageText = "Not enough disk space to record"
            a.informativeText = String(format: "Only %.1f GB free. Call Log needs at least %.0f GB. Free some space and try again.", free, minFreeGB)
            a.runModal()
            refresh()
            return
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/call-\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = Recorder(dir: dir)
        r.screens = captureScreens
        let mins = sender.tag
        Task {
            do {
                try await r.start()
                rec = r; endsAt = Date().addingTimeInterval(Double(mins) * 60)
                ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                    Task { @MainActor in
                        if let e = self.endsAt, e.timeIntervalSinceNow <= 0 { self.stopNow() }
                        else if freeGB() < minFreeGB {
                            // No pop-up mid-call (it could show on a shared screen): stop and flag it in the menu.
                            self.warning = String(format: "Stopped early at %@: disk below %.0f GB free", DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short), minFreeGB)
                            self.stopNow()
                        } else { self.refresh() }
                    }
                }
                refresh()
            } catch {
                try? FileManager.default.removeItem(at: dir)
                let a = NSAlert()
                a.messageText = "Couldn't start recording"
                a.informativeText = "Allow Call Log in System Settings > Privacy & Security > Screen & System Audio Recording, and Microphone, then try again.\n\n\(error.localizedDescription)"
                a.runModal()
            }
        }
    }

    @objc func stopNow() {
        guard let r = rec else { return }
        rec = nil; endsAt = nil; ticker?.invalidate(); ticker = nil
        item.button?.title = "◎ saving…"
        Task {
            await r.stop()
            last = r.dir
            refresh()
        }
    }

    @objc func toggleScreens() { captureScreens.toggle(); refresh() }

    @objc func toggleTimer() { showTimer.toggle(); refresh() }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        refresh()
    }

    @objc func showLast(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}

// Terminal test: CallLog --test 8 [screens]  (records, stops, prints the folder)
let args = CommandLine.arguments
if args.count > 2, args[1] == "--test", let secs = Double(args[2]) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/call-test")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = Recorder(dir: dir); r.screens = args.contains("screens")
    DispatchQueue.main.asyncAfter(deadline: .now() + secs + 20) { print("watchdog: timed out"); exit(2) }
    Task {
        do { try await r.start(); print("started") } catch { print("start failed: \(error)"); exit(1) }
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        await r.stop(); print(dir.path); exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

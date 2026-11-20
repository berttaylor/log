import AppKit
import ServiceManagement
import UserNotifications

/// Free space macOS can make available (includes purgeable space).
func freeGB() -> Double {
    let v = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1e9 } ?? .infinity
}
let minFreeGB = 5.0
/// "Log", or "Log Dev" for a development build (see build.sh). A dev build has its own
/// recordings folder, settings and permissions, and never opens at login, so it runs
/// happily next to the installed app.
let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Log"
let isDev = name != "Log"
let library = URL.downloadsDirectory.appendingPathComponent(name)

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
        item.menu = NSMenu()
        item.menu?.delegate = self
        item.button?.imagePosition = .imageLeading
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.stop(warning: "Stopped when the Mac went to sleep") }
        }
        update()
        // Finish any recording Log was killed in the middle of. The list is taken now, before a
        // new recording can start, so a live recording is never touched.
        let interrupted = interruptedRecordings()
        guard !interrupted.isEmpty else { return }
        Task.detached {
            let recovered = interrupted.filter { (try? finish($0)) != nil }
            await MainActor.run {
                guard self.state == .idle else { return }   // don't cover a live recording's status
                self.last = recovered.last ?? self.last
                self.warning = recovered.count == interrupted.count
                    ? "Recovered \(recovered.count == 1 ? "an interrupted recording" : "\(recovered.count) interrupted recordings")"
                    : "Couldn't recover \(interrupted.count - recovered.count) interrupted recording(s)"
                self.update()
            }
        }
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
        var title = isDev ? " dev" : ""   // tells a development build apart from the installed app
        if let left, defaults.bool(forKey: "showTimer") { title += " \(left)" }
        if warning != nil { title += " ⚠︎" }
        button.title = title
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
            if let warning { add(warning) }
            add("Recording \(rec?.screens == true ? "audio and screens" : "audio") · \(timeLeft ?? "") left")
            add("Stop now", #selector(stopNow), key: "s")
        case .saving: add("Saving…")
        }
        menu.addItem(.separator())
        add("Show Recordings", #selector(showRecordings))
        add("Capture Screens (1 frame a second)", state == .idle ? #selector(toggleScreens) : nil,
            on: defaults.bool(forKey: "captureScreens"))
        add("Show Timer in Menu Bar", #selector(toggleTimer), on: defaults.bool(forKey: "showTimer"))
        if !isDev { add("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled) }
        menu.addItem(.separator())
        add("Quit \(name)", #selector(NSApplication.terminate), key: "q", target: NSApp)
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
                try? await r.stop()
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
        else {
            // After 2 minutes, a side that has never had sound means broken capture: show a ⚠︎ in
            // the menu bar (never a pop-up). Quiet stretches later in a call are normal.
            let silent = (rec?.elapsed ?? 0) >= 120 ? rec?.silentSides() ?? [] : []
            warning = silent.isEmpty ? nil : "No sound from \(silent.joined(separator: " or ")) yet"
            update()
        }
    }

    @objc func stopNow() { stop() }

    func stop(warning: String? = nil) {
        guard state == .recording, let r = rec else { return }
        state = .saving; self.warning = warning
        ticker?.invalidate()
        update()
        let minutes = Int((r.elapsed / 60).rounded())
        let silent = r.silentSides()
        if warning == nil, !silent.isEmpty { self.warning = "Last recording has no sound from \(silent.joined(separator: " or "))" }
        saving = Task {
            do { try await r.stop() } catch { self.warning = "Some files couldn't be saved: \(error.localizedDescription)" }
            rec = nil; last = r.dir; saving = nil; state = .idle
            update()
            notify("Saved \(minutes == 0 ? "a short" : "a \(minutes) min") recording",
                   self.warning ?? "You and the other side were both heard.")
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

    /// Notifications stay hidden while the screen is shared or mirrored (a macOS default).
    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Clicking a notification shows the recording in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await showRecordings()
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


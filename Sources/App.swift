import AppKit
import ServiceManagement
import UserNotifications

/// Free space macOS can make available (includes purgeable space).
func freeGB() -> Double {
    let v = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1e9 } ?? .infinity
}
/// The longest recording: a call that never seems to end still stops after 4 hours.
let callMinutes = 240
/// Change with `defaults write work.bertbert.log minFreeGB -float 2`.
var minFreeGB: Double { UserDefaults.standard.object(forKey: "minFreeGB") as? Double ?? 5 }
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
    var last: URL?
    var warning: String?
    /// The call app using the mic right now, and since when. Polled every 3 seconds.
    var call: (app: String?, since: Date) = (nil, Date())
    var offered = false   // "Record this call?" already shown for the current call

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.menu?.delegate = self
        item.button?.imagePosition = .imageLeading
        defaults.register(defaults: ["detectCalls": true, "transcribe": true])
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }
        center.setNotificationCategories([UNNotificationCategory(identifier: "call", actions: [
            UNNotificationAction(identifier: "record", title: "Record"),
            UNNotificationAction(identifier: "ignore", title: "Never for This App"),
        ], intentIdentifiers: [])])
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task.detached {   // Core Audio queries stay off the main thread
                let app = callApp(in: audioProcesses())
                await self.tick(callApp: app)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.stop(warning: "Stopped when the Mac went to sleep") }
        }
        update()
        // Finish any recording Log was killed in the middle of. The list is taken now, before a
        // new recording can start, so a live recording is never touched.
        let interrupted = interruptedRecordings(), missing = untranscribed()
        transcribeInBackground(missing)
        guard !interrupted.isEmpty else { return }
        Task.detached {
            var finished: [URL] = []
            for dir in interrupted where (try? await finish(dir)) != nil {
                finished.append(dir)
                await self.transcribeInBackground([dir])
            }
            let recovered = finished
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

    /// Automation, for Shortcuts, Raycast, scripts or a keyboard shortcut (the dev build uses log-dev://):
    ///   log://record?minutes=60   log://record-call   log://stop   log://show
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "record":
                let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "minutes" }?.value
                record(minutes: min(max(minutes.flatMap(Int.init) ?? 60, 1), callMinutes))
            case "record-call": recordCall()
            case "stop": stop()
            case "show": showRecordings()
            default: break
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop()   // quitting, logging out or shutting down mid-call still saves the files
        guard let saving else { return .terminateNow }
        Task { await saving.value; sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Time left, or time so far for a recording that runs until the call ends.
    var clock: String? {
        guard state == .recording, let rec else { return nil }
        let s = max(0, Int(rec.app == nil ? endsAt.timeIntervalSinceNow.rounded(.up) : rec.elapsed))
        return String(format: "%d:%02d", s / 3600, s % 3600 / 60)
    }

    /// The menu bar shows only the icon (filled while recording), so it gives nothing away on a
    /// shared screen. The countdown is opt-in.
    func update() {
        guard let button = item.button else { return }
        let clock = clock
        button.image = clock == nil ? icons.idle : icons.recording
        button.appearsDisabled = state == .saving
        var title = isDev ? " dev" : ""   // tells a development build apart from the installed app
        if let clock, defaults.bool(forKey: "showTimer") { title += " \(clock)" }
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
            if let app = call.app { add("Record This \(app) Call", #selector(recordCall)); menu.addItem(.separator()) }
            for (title, mins) in [("30 minutes", 30), ("1 hour", 60), ("1½ hours", 90), ("2 hours", 120), ("2½ hours", 150)] {
                add("Record \(title)", #selector(record), tag: mins)
            }
        case .starting: add("Starting…")
        case .recording:
            if let warning { add(warning) }
            let what = rec?.screens == true ? "audio and screens" : "audio"
            if let app = rec?.app { add("Recording the \(app) call (\(what)) · stops when it ends") }
            else { add("Recording \(what) · \(clock ?? "") left") }
            add("Stop now", #selector(stopNow), key: "s")
        case .saving: add("Saving…")
        }
        menu.addItem(.separator())
        add("Show Recordings", #selector(showRecordings))
        add("Capture Screens (1 frame a second)", state == .idle ? #selector(toggleScreens) : nil,
            on: defaults.bool(forKey: "captureScreens"))
        add("Show Timer in Menu Bar", #selector(toggleTimer), on: defaults.bool(forKey: "showTimer"))
        add("Detect Calls", #selector(toggleDetect), on: defaults.bool(forKey: "detectCalls"))
        if #available(macOS 26, *) { add("Write Transcripts", #selector(toggleTranscribe), on: defaults.bool(forKey: "transcribe")) }
        if !isDev { add("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled) }
        menu.addItem(.separator())
        add("Quit \(name)", #selector(NSApplication.terminate), key: "q", target: NSApp)
    }

    @objc func record(_ sender: NSMenuItem) { record(minutes: sender.tag) }

    @objc func recordCall() { if let app = call.app { record(minutes: callMinutes, app: app) } }

    /// Starts recording for `minutes`; with a call `app`, it also stops when that call ends.
    func record(minutes: Int, app: String? = nil) {
        guard state == .idle else { return }
        let free = freeGB()
        guard free >= minFreeGB else {
            return alert("Not enough disk space to record",
                         String(format: "Only %.1f GB free. Log needs at least %.0f GB. Free some space and try again.", free, minFreeGB))
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = f.string(from: Date()) + (app.map { " " + $0 } ?? "")
        let r = Recorder(dir: library.appendingPathComponent(folder), screens: defaults.bool(forKey: "captureScreens"), app: app)
        r.onError = { error in Task { @MainActor in self.stop(warning: "Stopped early: \(error.localizedDescription)") } }
        rec = r; state = .starting; warning = nil; offered = true; update()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call"])
        Task {
            do {
                try await r.start()
                endsAt = Date(timeIntervalSinceNow: Double(minutes) * 60)
                state = .recording
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

    func tick(callApp detected: String?) {
        let app = defaults.bool(forKey: "detectCalls") ? detected : nil
        if app != call.app {
            call = (app, Date()); offered = false
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call"])
        }
        let lasted = -call.since.timeIntervalSinceNow
        if state == .idle, let app, lasted >= 10, !offered, !ignored.contains(app) {   // ignore anything under 10 s
            offered = true
            notify("Record this \(app) call?", "Log records until the call ends.", id: "call", app: app)
        }
        guard state == .recording else { return }
        if endsAt.timeIntervalSinceNow <= 0 { stop() }
        else if rec?.app != nil, call.app == nil, lasted >= 30 { stop() }   // the call ended (30 s rides out a muted mic)
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
            transcribeInBackground([r.dir])
        }
    }

    /// Writes transcripts one after another after saving, so they never hold up the next recording.
    func transcribeInBackground(_ dirs: [URL]) {
        guard #available(macOS 26, *), defaults.bool(forKey: "transcribe"), !dirs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for dir in dirs {
                do { try await transcribe(dir) } catch { await self.notify("Couldn't write the transcript", error.localizedDescription) }
            }
        }
    }

    @objc func showRecordings() {
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([last ?? library])
    }

    @objc func toggleScreens() { defaults.set(!defaults.bool(forKey: "captureScreens"), forKey: "captureScreens") }

    var ignored: [String] { defaults.stringArray(forKey: "ignoredCallApps") ?? [] }

    /// Turning detection back on also forgets the apps marked "Never for This App".
    @objc func toggleDetect() {
        let on = !defaults.bool(forKey: "detectCalls")
        defaults.set(on, forKey: "detectCalls")
        if on { defaults.removeObject(forKey: "ignoredCallApps") }
    }

    @objc func toggleTranscribe() { defaults.set(!defaults.bool(forKey: "transcribe"), forKey: "transcribe") }

    @objc func toggleTimer() { defaults.set(!defaults.bool(forKey: "showTimer"), forKey: "showTimer"); update() }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        if s.status == .enabled { try? s.unregister() } else { try? s.register() }
    }

    /// Notifications stay hidden while the screen is shared or mirrored (a macOS default).
    func notify(_ title: String, _ body: String, id: String = UUID().uuidString, app: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if let app { content.categoryIdentifier = "call"; content.userInfo = ["app": app] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// "Record this call?" records (by click or button) or ignores the app; any other
    /// notification shows the recording in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let app = response.notification.request.content.userInfo["app"] as? String, action = response.actionIdentifier
        await MainActor.run {
            switch (app, action) {
            case (let app?, "ignore"): defaults.set(ignored + [app], forKey: "ignoredCallApps")
            case (let app?, _): record(minutes: callMinutes, app: app)
            default: showRecordings()
            }
        }
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


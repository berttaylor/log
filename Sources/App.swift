import AppKit
import Carbon.HIToolbox
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
    var timed = true   // false: runs until stopped (or the call ends), so the clock counts up

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
        if !isDev {   // the installed app owns the shortcuts
            Hotkeys.register([(kVK_ANSI_R, { MainActor.assumeIsolated { self.toggleRecording() } }),
                              (kVK_ANSI_M, { MainActor.assumeIsolated { self.mark() } })])
        }
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
        if !defaults.bool(forKey: "consentShown") {   // once, on first launch
            defaults.set(true, forKey: "consentShown")
            alert("Before you record", """
                Log records your microphone and everything your Mac plays. Tell people when you're recording \
                them, and only record calls you're allowed to: in many places everyone on the call has to agree.

                "Copy Consent Message" in the menu puts a short note on the clipboard to paste into the call's chat.
                """)
        }
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
    ///   log://record?minutes=60   log://record-call   log://mark   log://stop   log://show   log://copy-for-ai
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "record":
                let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "minutes" }?.value
                record(minutes: min(max(minutes.flatMap(Int.init) ?? 60, 1), callMinutes))
            case "record-call": recordCall()
            case "stop": stop()
            case "mark": mark()
            case "show": showRecordings()
            case "copy-for-ai": copyForAI()
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
        let s = max(0, Int(timed ? endsAt.timeIntervalSinceNow.rounded(.up) : rec.elapsed))
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
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, key: String = "", on: Bool? = nil, tag: Int = 0,
                 object: Any? = nil, target: AnyObject? = nil, to parent: NSMenu? = nil) -> NSMenuItem {
            let m = (parent ?? menu).addItem(withTitle: title, action: action, keyEquivalent: key)
            m.target = target ?? self; m.tag = tag; m.representedObject = object
            if let on { m.state = on ? .on : .off }
            return m
        }
        func submenu(_ title: String) -> NSMenu {
            let sub = NSMenu()
            add(title).submenu = sub
            return sub
        }
        switch state {
        case .idle:
            if let warning { add(warning); menu.addItem(.separator()) }
            if let app = call.app { add("Record This \(app) Call", #selector(recordCall)) }
            add("Start Recording", #selector(startRecording))
            let durations = submenu("Record For")
            for (title, mins) in [("30 Minutes", 30), ("1 Hour", 60), ("1½ Hours", 90), ("2 Hours", 120), ("2½ Hours", 150)] {
                add(title, #selector(record), tag: mins, to: durations)
            }
        case .starting: add("Starting…")
        case .recording:
            if let warning { add(warning) }
            let what = rec?.screens == true ? "audio and screens" : "audio"
            if let app = rec?.app { add("Recording the \(app) call (\(what)) · stops when it ends") }
            else { add("Recording \(what) · \(clock ?? "")\(timed ? " left" : "")") }
            add("Mark This Moment", #selector(mark))
            add("Stop Recording", #selector(stopNow), key: "s")
        case .saving: add("Saving…")
        }
        menu.addItem(.separator())
        let recent = recentRecordings()
        if !recent.isEmpty {
            let list = submenu("Recent")
            for dir in recent { add(title(of: dir), #selector(reveal), object: dir, to: list) }
        }
        add("Show Recordings", #selector(showRecordings))
        if let newest = recent.first, exists(newest.appendingPathComponent("transcript.md")) { add("Copy Last Call for AI", #selector(copyForAI)) }
        add("Copy Consent Message", #selector(copyConsent))
        menu.addItem(.separator())
        let settings = submenu("Settings")
        add("Capture Screens (1 frame a second)", state == .idle ? #selector(toggleScreens) : nil,
            on: defaults.bool(forKey: "captureScreens"), to: settings)
        let mics = NSMenu(), available = microphones()
        let chosen = defaults.string(forKey: "microphone").flatMap { id in available.contains { $0.uniqueID == id } ? id : nil }
        add("Microphone", to: settings).submenu = mics
        add("Automatic (Built-in)", #selector(chooseMic), on: chosen == nil, to: mics)
        for mic in available { add(mic.localizedName, #selector(chooseMic), on: chosen == mic.uniqueID, object: mic.uniqueID, to: mics) }
        add("Detect Calls", #selector(toggleDetect), on: defaults.bool(forKey: "detectCalls"), to: settings)
        if #available(macOS 26, *) { add("Write Transcripts", #selector(toggleTranscribe), on: defaults.bool(forKey: "transcribe"), to: settings) }
        add("Show Timer in Menu Bar", #selector(toggleTimer), on: defaults.bool(forKey: "showTimer"), to: settings)
        if !isDev { add("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled, to: settings) }
        settings.addItem(.separator())
        add("⌃⌥⌘R starts or stops recording, ⌃⌥⌘M marks a moment", to: settings)
        menu.addItem(.separator())
        add("Quit \(name)", #selector(NSApplication.terminate), key: "q", target: NSApp)
    }

    /// The five newest recordings.
    func recentRecordings() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        return Array(dirs.filter { exists(Meta.url($0)) }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(5))
    }

    /// "20 Nov, 14:30 · Zoom · 43 min"
    func title(of dir: URL) -> String {
        guard let meta = Meta.read(dir) else { return dir.lastPathComponent }
        let when = meta.started.formatted(.dateTime.day().month().hour().minute())
        let minutes = meta.duration.map { " · \(max(1, Int(($0 / 60).rounded()))) min" } ?? ""
        return when + (meta.app.map { " · " + $0 } ?? "") + minutes
    }

    @objc func reveal(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        let main = ["Call.mp4", "Call.m4a"].map(dir.appendingPathComponent).first(where: exists)
        NSWorkspace.shared.activateFileViewerSelecting([main ?? dir])
    }

    static let consent = "Just so you know, I'm recording this call so I can go back over it later. Let me know if you'd rather I didn't."

    @objc func copyConsent() { copy(App.consent) }

    /// The newest call's transcript with a prompt, to paste into any AI chat. A large model
    /// summarises far better than the small one on this Mac.
    @objc func copyForAI() {
        guard let url = recentRecordings().first?.appendingPathComponent("transcript.md"),
              let transcript = try? String(contentsOf: url, encoding: .utf8) else {
            return notify("No transcript to copy", "The newest recording has no transcript yet.")
        }
        copy("""
            Here is the transcript of a call I recorded. "Me" is me and "Them" is everyone else; ⚑ marks moments \
            I flagged as important. Summarise the call, list the decisions and the action items (who, what, by \
            when), and point out anything I should follow up on.
            """ + "\n\n" + transcript)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func chooseMic(_ sender: NSMenuItem) { defaults.set(sender.representedObject as? String, forKey: "microphone") }

    @objc func startRecording() { record(minutes: callMinutes, timed: false) }

    @objc func mark() { if state == .recording { rec?.mark() } }

    @objc func toggleRecording() { state == .idle ? startRecording() : stop() }

    @objc func record(_ sender: NSMenuItem) { record(minutes: sender.tag) }

    @objc func recordCall() { if let app = call.app { record(minutes: callMinutes, app: app, timed: false) } }

    /// Starts recording for at most `minutes`; with a call `app`, it also stops when that call ends.
    func record(minutes: Int, app: String? = nil, timed: Bool = true) {
        guard state == .idle else { return }
        let free = freeGB()
        guard free >= minFreeGB else {
            return alert("Not enough disk space to record",
                         String(format: "Only %.1f GB free. Log needs at least %.0f GB. Free some space and try again.", free, minFreeGB))
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = f.string(from: Date()) + (app.map { " " + $0 } ?? "")
        let r = Recorder(dir: library.appendingPathComponent(folder), screens: defaults.bool(forKey: "captureScreens"),
                         app: app, mic: defaults.string(forKey: "microphone"))
        r.onError = { error in Task { @MainActor in self.stop(warning: "Stopped early: \(error.localizedDescription)") } }
        rec = r; state = .starting; warning = nil; offered = true; self.timed = timed; update()
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
            case (let app?, _): record(minutes: callMinutes, app: app, timed: false)
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


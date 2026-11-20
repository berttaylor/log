// Log: a macOS menu bar app that records both sides of a call. It saves what your Mac plays
// and what your microphone hears as aligned tracks, plus, optionally, every screen at
// one frame a second.
//
// Each recording gets a folder in ~/Downloads/Log: see Files.swift for its layout.
//
// Build: ./build.sh. From a terminal ("build/Log Dev.app/Contents/MacOS/Log"):
//   --test <seconds> [screens] [transcript]   records, stops and prints the folder
//   --recover                    finishes recordings that were interrupted, prints their folders
//   --check                      runs the self-checks and lists apps using audio right now
import AppKit

/// Self-checks for logic that can be tested without capturing anything.
func check() {
    func p(_ id: String, input: Bool = true, output: Bool = false) -> AudioProcess { AudioProcess(bundleID: id, input: input, output: output) }
    precondition(callApp(in: [p("us.zoom.xos")]) == "Zoom")
    precondition(callApp(in: [p("com.electron.wispr-flow")]) == nil, "dictation is not a call")
    precondition(callApp(in: [p("com.apple.replayd")]) == nil, "Log's own capture is not a call")
    precondition(callApp(in: [p("com.google.Chrome.helper")]) == nil, "browser dictation is not a call")
    precondition(callApp(in: [p("com.google.Chrome.helper"), p("com.google.Chrome.helper.renderer", input: false, output: true)]) == "Chrome")
    precondition(callApp(in: [p("us.zoom.xos", input: false, output: true)]) == nil, "playing sound alone is not a call")
    let them = Line(start: 1, end: 4, speaker: "Them", text: "Can you share the dashboard?")
    let bleed = Line(start: 1.2, end: 4.1, speaker: "Me", text: "can you share the dashboard")
    let reply = Line(start: 4.5, end: 6, speaker: "Me", text: "Sure, one second.")
    precondition(merge(me: [bleed, reply], them: [them]) == [them, reply], "speaker bleed is dropped from Me")
    precondition(markdown([them, reply], title: "Call") == "# Call\n\n**0:01 Them:** Can you share the dashboard?\n\n**0:04 Me:** Sure, one second.\n")
    print("checks passed")
    for p in audioProcesses() where p.input || p.output { print(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID, p.input ? "mic" : "", p.output ? "playing" : "") }
    print("call app:", callApp(in: audioProcesses()) ?? "none")
}

/// Records to <library>/test, stops, prints the folder.
func test(seconds: Double, screens: Bool, transcript: Bool) {
    let r = Recorder(dir: library.appendingPathComponent("test"), screens: screens)
    try? FileManager.default.removeItem(at: r.dir)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 60) { print("timed out"); exit(2) }
    Task {
        do { try await r.start() } catch { print("start failed: \(error)"); exit(1) }
        try await Task.sleep(for: .seconds(seconds))
        print("silent:", r.silentSides())
        do { try await r.stop() } catch { print("save failed: \(error)") }
        if transcript, #available(macOS 26, *) {
            do { try await transcribe(r.dir) } catch { print("transcript failed: \(error)") }
        }
        print(r.dir.path)
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared   // ScreenCaptureKit needs this, even in test mode
    app.setActivationPolicy(.accessory)
    let args = Array(CommandLine.arguments.dropFirst())
    var delegate: App?
    switch args.first {
    case "--test": test(seconds: Double(args.dropFirst().first ?? "") ?? 5, screens: args.contains("screens"), transcript: args.contains("transcript"))
    case "--check": check(); exit(0)
    case "--recover":
        Task {
            for dir in interruptedRecordings() { print(dir.path, (try? await finish(dir)) == nil ? "failed" : "recovered") }
            exit(0)
        }
    default: delegate = App(); app.delegate = delegate
    }
    withExtendedLifetime(delegate) { app.run() }
}

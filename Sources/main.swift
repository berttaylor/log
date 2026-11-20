// Log: a macOS menu bar app that records both sides of a call. It saves what your Mac plays
// and what your microphone hears as aligned tracks, plus, optionally, every screen at
// one frame a second.
//
// Files go to ~/Downloads/Log/<date-time>/: me.m4a, them.m4a, call.m4a (you left, them right)
// and screen-1.mov, screen-2.mov, ... when screens are on.
//
// Build: ./build.sh. From a terminal ("build/Log Dev.app/Contents/MacOS/Log"):
//   --test <seconds> [screens]   records, stops and prints the folder
//   --recover                    finishes recordings that were interrupted, prints their folders
import AppKit

/// Records to <library>/test, stops, prints the folder.
func test(seconds: Double, screens: Bool) {
    let r = Recorder(dir: library.appendingPathComponent("test"), screens: screens)
    try? FileManager.default.removeItem(at: r.dir)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 60) { print("timed out"); exit(2) }
    Task {
        do { try await r.start() } catch { print("start failed: \(error)"); exit(1) }
        try await Task.sleep(for: .seconds(seconds))
        print("silent:", r.quietSides())
        do { try await r.stop() } catch { print("save failed: \(error)") }
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
    case "--test": test(seconds: Double(args.dropFirst().first ?? "") ?? 5, screens: args.contains("screens"))
    case "--recover":
        for dir in interruptedRecordings() { print(dir.path, (try? finish(dir)) == nil ? "failed" : "recovered") }
        exit(0)
    default: delegate = App(); app.delegate = delegate
    }
    withExtendedLifetime(delegate) { app.run() }
}

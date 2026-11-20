import CoreAudio

/// Finds a call by asking Core Audio which apps have the microphone open. Only known call apps
/// count, so dictation apps (Wispr Flow, Superwhisper), Siri and Voice Memos never do. A browser
/// counts only while it is also playing sound, as a call does; voice typing in a browser while
/// another tab plays music would still count, and Log only asks, so that is harmless. Log's own
/// capture runs in macOS's com.apple.replayd, which is on no list.
let callApps: [(name: String, ids: [String], browser: Bool)] = [
    ("Zoom", ["us.zoom."], false),
    ("Teams", ["com.microsoft.teams"], false),
    ("FaceTime", ["com.apple.FaceTime", "com.apple.avconferenced"], false),
    ("Slack", ["com.tinyspeck.slackmacgap"], false),
    ("Discord", ["com.hnc.Discord"], false),
    ("WhatsApp", ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], false),
    ("Webex", ["Cisco-Systems.Spark"], false),
    ("Signal", ["org.whispersystems.signal-desktop"], false),
    ("Telegram", ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"], false),
    ("Chrome", ["com.google.Chrome"], true),
    ("Safari", ["com.apple.Safari", "com.apple.WebKit"], true),
    ("Firefox", ["org.mozilla.firefox"], true),
    ("Edge", ["com.microsoft.edgemac"], true),
    ("Arc", ["company.thebrowser."], true),
    ("Brave", ["com.brave.Browser"], true),
]

struct AudioProcess { let bundleID: String, input: Bool, output: Bool }

/// The call app using the microphone right now, if any.
func callApp(in processes: [AudioProcess]) -> String? {
    callApps.first { app in
        let mine = processes.filter { p in app.ids.contains { p.bundleID.hasPrefix($0) } }
        return mine.contains(where: \.input) && (!app.browser || mine.contains(where: \.output))
    }?.name
}

/// Every process Core Audio knows about, with whether it is recording and playing (macOS 14+).
func audioProcesses() -> [AudioProcess] {
    func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var a = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr && value != 0
    }
    var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        var b = address(kAudioProcessPropertyBundleID), name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &b, 0, nil, &nameSize, &name)
        return AudioProcess(bundleID: name?.takeRetainedValue() as String? ?? "",
                            input: flag(id, kAudioProcessPropertyIsRunningInput),
                            output: flag(id, kAudioProcessPropertyIsRunningOutput))
    }
}

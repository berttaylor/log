# Log

macOS menu bar app that records both sides of a call. App code is in `Sources/`: `main.swift` (entry point, terminal modes), `App.swift` (menu bar UI and state), `Recorder.swift` (capture), `Files.swift` (turning raw captures into finished files), `Detect.swift` (which call app is using the mic), `Transcribe.swift` (transcript.md, macOS 26+), `Hotkeys.swift` (⌃⌥⌘R, ⌃⌥⌘M). `build.sh` builds the app; there is no Xcode project and there are no dependencies.

The competitive analysis, feature spec (M1-M11, L1-L7) and release plan are in `docs/ROADMAP.md`. Build features in its release order, and keep to its "what not to build" list.

## Dev build vs installed app

The owner runs the released Log from /Applications every day while developing in this repo. The two must never collide:

- `./build.sh` (no argument) builds `build/Log Dev.app`, bundle id `work.bertbert.log.dev`. Use this for all development and testing.
- `./build.sh release` builds `build/Log.app` (bundle id `work.bertbert.log`) and `build/Log.dmg`. Use it only when shipping a release.
- The app reads its name from `CFBundleName`. "Log Dev" gets its own UserDefaults, its own privacy permissions, recordings in `~/Downloads/Log Dev/`, and no "Open at Login" item. Keep it that way: don't hard-code "Log" for paths, settings or login items.
- Never copy a build over /Applications/Log.app, and never run the release build from `build/`. Running it from there can register `build/` as the login item path.

## Testing

- Build, then run `"build/Log Dev.app/Contents/MacOS/Log" --test 5 screens` records 5 seconds to `~/Downloads/Log Dev/test/` and prints the folder. It needs Microphone and Screen & System Audio Recording permission for the terminal app.
- Crash safety: start `--test 60 screens` in the background, `kill -9` it after ~20 s, then run `--recover`. The `.caf` tracks and `.mov` screens must still play, and `--recover` must produce the `.m4a` files.
- Check audio with `afinfo` or `ffprobe`. In `call.m4a`, the left channel is `me.m4a` and the right is `them.m4a`.
- The menu bar UI can't be checked from the terminal: ask the owner to look.

- `--test 12 transcript` also writes transcript.md; play speech with `say` during it to check labels and echo removal.
- `--check` runs the self-checks (call detection rules, transcript merging) and lists apps using audio right now.
- To test call detection end to end without a real call: build a fake app bundle with a bundle id starting `us.zoom.` whose binary opens the mic (AVAudioEngine input tap), run its binary from the terminal so it inherits the terminal's mic permission, run the dev app's binary from the terminal too, then `open "log-dev://record-call"`. The dev build uses the `log-dev://` scheme.
- Before driving the dev app from the terminal, run `defaults write work.bertbert.log.dev consentShown -bool true`, or the one-time consent alert blocks it. `open log-dev://record?minutes=1`, `log-dev://mark` and `log-dev://stop` drive a recording.
- Low disk blocks recording (default 5 GB). For testing: `defaults write work.bertbert.log.dev minFreeGB -float 1`.

## Releasing

1. Bump `VERSION` in `build.sh`.
2. `./build.sh release`
3. `gh release create vX.Y.Z build/Log.dmg -R berttaylor/log --title "Log X.Y.Z" --notes "..."`

The README links to `releases/latest/download/Log.dmg`, so the asset must keep that name. Builds are ad-hoc signed, not notarized. The README's install steps explain "Open Anyway".

## Workflow

Each roadmap item ships as its own branch and PR: build, run the terminal tests, then review (simplify and caveman review) before merging to `main`. Every PR updates the README when behaviour changes. The dev build shows "dev" next to its menu bar icon.

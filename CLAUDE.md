# Log

macOS menu bar app that records both sides of a call. All app code is in `Log.swift`. `build.sh` builds the app; there is no Xcode project and there are no dependencies.

## Dev build vs installed app

The owner runs the released Log from /Applications every day while developing in this repo. The two must never collide:

- `./build.sh` (no argument) builds `build/Log Dev.app`, bundle id `work.bertbert.log.dev`. Use this for all development and testing.
- `./build.sh release` builds `build/Log.app` (bundle id `work.bertbert.log`) and `build/Log.dmg`. Use it only when shipping a release.
- The app reads its name from `CFBundleName`. "Log Dev" gets its own UserDefaults, its own privacy permissions, recordings in `~/Downloads/Log Dev/`, and no "Open at Login" item. Keep it that way: don't hard-code "Log" for paths, settings or login items.
- Never copy a build over /Applications/Log.app, and never run the release build from `build/`. Running it from there can register `build/` as the login item path.

## Testing

- `"build/Log Dev.app/Contents/MacOS/Log" --test 5 screens` records 5 seconds to `~/Downloads/Log Dev/test/` and prints the folder. It needs Microphone and Screen & System Audio Recording permission for the terminal app.
- Check audio with `afinfo` or `ffprobe`. In `call.m4a`, the left channel is `me.m4a` and the right is `them.m4a`.
- The menu bar UI can't be checked from the terminal: ask the owner to look.

## Releasing

1. Bump `VERSION` in `build.sh`.
2. `./build.sh release`
3. `gh release create vX.Y.Z build/Log.dmg -R berttaylor/log --title "Log X.Y.Z" --notes "..."`

The README links to `releases/latest/download/Log.dmg`, so the asset must keep that name. Builds are ad-hoc signed, not notarized. The README's install steps explain "Open Anyway".

# Call Log

A tiny macOS menu bar app that records calls for later review.

- **Audio:** the call audio (whatever the Mac plays, on any output device: AirPods, headphones or speakers) and the MacBook's built-in mic, as two aligned tracks, plus a stereo mix (you on the left, them on the right).
- **Screens (optional toggle):** every display at one frame a second, as `screen-N.mp4`.
- **Timed:** pick 30 min to 2½ hours from the menu; it stops by itself. "Stop now" ends early.
- **Discreet:** the menu bar shows only ● while recording (the countdown is an optional toggle).
- **Disk-safe:** won't start below 5 GB free, and stops cleanly if free space drops below 5 GB mid-call.
- Opens at login (toggle in the menu).

Recordings go to `~/Downloads/call-<date-time>/`: `me.m4a`, `them.m4a`, `call.m4a`, and `screen-N.mp4` if screens are on.

Uses ScreenCaptureKit (macOS 15+), so there's no audio driver to install. ffmpeg (`/opt/homebrew/bin/ffmpeg`) makes the stereo mix.

## Build

```sh
./build-call-log.sh   # builds ~/Applications/Call Log.app
```

The app is ad-hoc signed with a designated requirement pinned to its bundle id, so macOS privacy permissions survive rebuilds. On first use, allow **Call Log** under System Settings > Privacy & Security > **Microphone** and **Screen & System Audio Recording**.

## Test from a terminal

```sh
"$HOME/Applications/Call Log.app/Contents/MacOS/CallLog" --test 8 screens
```

Records 8 seconds to `~/Downloads/call-test/`. When run from a terminal, macOS attributes capture to the terminal app, so it needs the same permissions.

Ask the other people on the call before recording.

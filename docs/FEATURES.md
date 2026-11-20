# Key feature rating

How Log compares with the call recorders people actually pay for, on the features users ask for most (see [ROADMAP.md](ROADMAP.md) for the research behind the list). ✓ has it, ~ partly, ✗ doesn't, ? not confirmed. Rival data is from their own sites and reviews as of November 2026, so treat it as a snapshot.

| Feature | Log | Granola | Otter | Fathom | Krisp | MacWhisper | Audio Hijack | Piezo | Diphony | Meetily | Anarlog | Apple Phone/FaceTime |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Records any call app, no bot | ✓ | ✓ | ~ | ~ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| Works offline, no account | ✓ | ✗ | ✗ | ✗ | ~ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ~ |
| Keeps the audio | ✓ | ✗ | ✓ | ~ | ✓ | ✓ | ✓ | ✓ | ✓ | ? | ✓ | ✓ |
| You and them on separate tracks | ✓ | ✗ | ? | ? | ? | ? | ✓ | ✓ | ✓ | ✗ | ? | ? |
| Records the screens | ✓ | ✗ | ✗ | ~ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Every display in one video | ✓ | ✗ | ✗ | ✗ | ? | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Notices calls and offers to record | ✓ | ✓ | ? | ? | ? | ~ | ~ | ? | ? | ~ | ~ | ✗ |
| Stops when the call ends | ✓ | ? | ? | ? | ? | ? | ~ | ? | ? | ? | ? | ✓ |
| Survives a crash or power cut | ✓ | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Transcript made on your Mac | ✓ | ✗ | ✗ | ✗ | ~ | ✓ | ✓ | ✗ | ~ | ✓ | ✓ | ✓ |
| Who said what | ✓ | ✓ | ✓ | ✓ | ? | ✓ | ✓ | ✗ | ✓ | ~ | ? | ? |
| AI summary | ~ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ |
| Mark moments during the call | ✓ | ~ | ? | ✓ | ? | ? | ✗ | ✗ | ? | ? | ~ | ✗ |
| Keyboard shortcut to start and stop | ✓ | ? | ? | ? | ? | ? | ✓ | ? | ? | ? | ? | ✗ |
| Automation or agent access | ✓ | ✓ | ✓ | ✓ | ✓ | ? | ✓ | ✗ | ? | ~ | ✓ | ✗ |
| Consent helper | ✓ | ✗ | ? | ? | ? | ? | ✗ | ✗ | ✗ | ? | ? | ✓ |
| Open source | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ |
| Price | free | $14/mo | $8–17/mo | $16–20/mo | $8–16/mo | €59–64 | $69 | $29 | $19.99 | free, Pro $10/mo | free | free |
| **Rating (✓ = 1, ~ = ½, out of 17)** | **16½** | 5½ | 4½ | 5½ | 6 | 6½ | 9 | 4 | 5½ | 6½ | 8 | 5½ |

Unconfirmed cells count as zero, so rivals may score a little higher than shown. On what can be checked, Log covers more of the list than any of them.

## Notes on Log's entries

- **AI summary (~).** Log doesn't summarise on your Mac. We tested Apple's on-device model on a call transcript: it took 29 seconds, swapped who was meant to do what, and missed two of six action items. Its 4,096-token limit also means an hour-long call would have to be chopped up. Instead, **Copy Last Call for AI** puts the transcript and a prompt on the clipboard, so any chatbot you already use (Claude, ChatGPT, Gemini) writes the summary, in any language.
- **Transcript.** Needs macOS 26 or later. It's made with Apple's speech recognition, which is about as accurate as Whisper Small. For a better transcript, give `Call.mp4` or the separate tracks to a larger model.
- **Separate tracks.** You and the other side. Several people on the other side share one track; the transcript calls them all "Them".
- **Automation.** `log://` links (for Shortcuts, Raycast or scripts), a fixed folder layout and `meta.json`. There's no MCP server: any agent that can read files can read a recording.

## Not built, on purpose

- **A bot, an account or a cloud.** Log's point is that recordings stay as plain files on your Mac.
- **A library window or editor.** Finder, QuickTime and Spotlight (which indexes the transcripts) already do this.
- **Per-app capture** (recording only Zoom's sound, not a notification chime). Useful, but FaceTime plays its audio through a system service rather than the app, so filtering by app would silently drop FaceTime calls.

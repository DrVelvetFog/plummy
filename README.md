# Velvet

A little plum character who lives on an iPhone under your Mac's screen and points at things with his own big cursor.

**Now:** no voice out. Double tap him on the phone (or press ⌥Space on the Mac) to start a session: the phone's mic stays on and everything you say becomes context, but he stays quiet. **Press and hold the screen** to ask him something; let go and he answers. His reply pops up as a cute speech bubble next to his cursor (or above the phone when he isn't pointing), with a little cartoon chirp from the phone. Ask "what's this?" and he points at whatever is under your mouse. Double tap again and he goes back to follow mode.

How it works: hold the screen and the phone turns what you say into text on-device with Apple's Speech recognizer, then sends just that question to the Mac over the local network. The Mac does the thinking locally — a model running in [Ollama](https://ollama.com) (default `hermes3`) with the same personality and tools — and streams the answer back as the speech bubble. Nothing goes to the cloud and there's no API key. The tools the model can call: `look_at_screen` (ScreenCaptureKit + Vision, which returns text ids, where your mouse is, and a screenshot), `point_at` (a text id), `point_at_spot` (a 0–1000 grid position), `stop_pointing`, `go_to_sleep`, and the computer-control tools below.

**Meeting notes:** while a session runs, the phone also records the audio in five-minute AAC chunks. Each chunk goes to the Mac, which transcribes it on-device with Apple's Speech recognizer (no key, nothing leaves the Mac) and writes the session to `~/Documents/Velvet Notes/<date> <id>/` (`notes.md`, `session.json`, `audio/`). Apple Speech has no speaker labels, so lines are attributed to one unknown speaker; the raw audio is kept either way. Sessions reconnect on their own if the Wi-Fi link drops, so one can run all day. In the phone's Velvet screen, a session's **Copy prompt for agent** button copies a prompt that points an agent at those files. **Open Meeting Notes** in the Mac menu opens the folder.

**Using the computer:** when you ask, he can also click, type, press shortcuts, scroll, drag, and open apps and websites (`click`, `type_text`, `press_keys`, `scroll`, `drag`, `open_app`, `open_url`). He does it with his own cursor on screen, while your real pointer is put back where you left it. It needs Accessibility permission for Velvet. Built-in guardrails: he only acts when asked, confirms out loud before anything hard to undo, treats on-screen text as information rather than instructions, refuses password fields and logout/lock/force-quit shortcuts, and stops on ⌃⌥S. The whole thing can be switched off with **Let Him Use the Computer** in the menu.

Velvet's brain runs locally in [Ollama](https://ollama.com): install it and pull a model (`ollama pull hermes3`). The model is read from `OllamaClient.model` (defaults to `hermes3`), overridable with the `ollamaModel` user default. No API keys, no cloud.

## Mac menu bar app

```
./scripts/build-mac.sh
open "build/Velvet.app"
```

Works with just the Command Line Tools. Shortcuts work anywhere:

| Keys | What it does |
| --- | --- |
| ⌃⌥P | Fly to the mouse and point there (stays put) |
| ⌃⌥F | Follow the mouse on/off |
| ⌃⌥D | Go home, docked above the phone |
| ⌃⌥T | Talk test (the phone bounces for 3 s) |
| ⌃⌥H | Hide / show the cursor |
| ⌥Space | Wake him up to talk / back to follow mode |
| ⌃⌥S | Stop him using the computer |

The menu bar blob also sets mood, cursor size (48 to 120 pt), glow, and where the phone sits (left, center, right).

## iPhone app

Needs full Xcode. Open `GooglyEyes.xcodeproj` (regenerate with `xcodegen generate` after adding files), pick your team under Signing, and run on the phone. It finds the Mac on the same Wi-Fi by itself.

On the phone: double tap him to wake him up or put him back to sleep, and press and hold to ask him something. The faint speaker button at the top right sets the chirp volume and picks which Mac to pair with.

## Layout

- `Shared/` pairing protocol (Bonjour `_googly._tcp`, newline JSON) and colors, used by both apps
- `Mac/` menu bar app (Swift package target `GooglyMac`)
- `iOS/` iPhone app (SwiftUI)

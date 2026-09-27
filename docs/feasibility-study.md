# NVDA Remote for macOS: feasibility study

Date: September 10, 2026.
Source examined: the `nvaccess/nvda` repository, commit `dd2bccb` (September 10, 2026), module `source/_remoteClient/` (17 files, roughly 5,300 lines). Since NVDA 2025.1, the former NVDA Remote add-on has been built into NVDA itself under the name "Remote Access". The network protocol has remained compatible with add-on version 2.6.x.

Goal: control a Windows PC running NVDA from a Mac. The Mac therefore acts as the **controller** ("leader", `master` on the wire) and the PC as the **controlled** machine ("follower", `slave`). No code has been written at this stage.

---

## 1. Existing work

| Project | Platforms | Strengths | Known limitations |
|---|---|---|---|
| NVDARemote (App Store, Malte Schoeppe, free, v1.4 from January 2025) | iPhone, iPad, Vision Pro, Apple silicon Mac (as an iPad app) | Quasi-official client, built-in TTS, sends Ctrl, Alt, Windows, Escape, F1–F12 | Requires an external keyboard, no braille, broken TTS rate slider, volume follows the ringer rather than media, not designed for macOS |
| nvdr (ogomez92, GPL) | Rust CLI for Linux, SwiftUI Mac app, iOS, Android, NVDA add-on | Native Mac app, system-wide keyboard capture via `CGEventTap` + `IOHIDManager`, "leader" key for Windows keys | Always goes through an SSH bridge on a third machine, no braille, no NVDA beeps or sounds, does not distinguish left and right modifiers |

Conclusion: there is no complete, native macOS client that connects directly (without a bridge) and offers interruptible speech, sounds and braille. That is the gap to fill.

---

## 2. How Remote Access works (from reading the code)

### 2.1 Architecture

Three roles:

- **Relay**: a server with no logic of its own. When an authenticated client sends a message, the relay broadcasts it to every other client in the channel, adding an `origin` field (the sender's client ID). Two kinds of relay are possible:
  - `nvdaremote.com:6837` (the public relay). Valid Let's Encrypt certificate, TLS 1.3, checked today with `openssl s_client`: `Verify return code: 0 (ok)`. A Mac client can therefore rely on the system's standard TLS validation.
  - NVDA itself in "Host locally" mode (`server.py`). Self-signed "NVDA Remote Access Service" certificate, renewed every 365 days. The client checks the SHA-256 fingerprint of the DER certificate and remembers it (trust on first use).
- **Leader** (controller): captures the keyboard and sends it; receives speech, sounds and braille.
- **Follower** (controlled PC): injects the keys it receives; sends back its speech, beeps, sounds and braille cells.

The relay accepts several leaders and several followers in the same channel, and everything is broadcast to everyone. A client must therefore ignore messages that are not meant for it (for example `key` messages sent by another leader).

### 2.2 Transport

- TCP + TLS (the NVDA client requires TLS 1.2; the public relay negotiates TLS 1.3).
- UTF-8 JSON messages, one per line, terminated by `\n`. The `type` field is mandatory.
- `TCP_NODELAY` enabled, TCP keepalive (1 minute), automatic reconnection every 5 seconds, server `ping` every 5 minutes (no reply expected).
- Messages sent before the connection is established are dropped, not queued.

Files: `transport.py` (connection, line-by-line reading, fingerprint), `serializer.py` (JSON), `protocol.py` (list of message types).

### 2.3 Handshake

```
→ {"type": "protocol_version", "version": 2}
→ {"type": "join", "channel": "<key>", "connection_type": "master"}
← {"type": "channel_joined", "channel": "<key>", "user_ids": [3], "clients": [{"id": 3, "connection_type": "slave"}]}
```

Then, over the course of the session:

```
← {"type": "client_joined", "user_id": 4, "client": {"id": 4, "connection_type": "slave"}, "origin": 4}
← {"type": "client_left",   "user_id": 4, "client": {"id": 4, "connection_type": "slave"}, "origin": 4}
← {"type": "motd", "motd": "text", "force_display": false}
← {"type": "version_mismatch"}
← {"type": "error", "message": "incorrect_password"}        (local NVDA server only)
← {"type": "nvda_not_connected"}                             (defined in the protocol, never implemented on the server side)
```

The key serves as both the channel identifier and the password. To have the server generate a key: connect, send `protocol_version` followed by `{"type": "generate_key"}` instead of `join`, receive `{"type": "generate_key", "key": "..."}`, then disconnect.

### 2.4 Messages received by the controller (from the PC)

| Type | Fields | Meaning |
|---|---|---|
| `speak` | `sequence`, `priority` (0 normal, 1 next, 2 now) | NVDA speech; see the format below |
| `cancel` | none | NVDA has interrupted its speech (key pressed, etc.). Must be handled **immediately**: this is what makes reading feel responsive |
| `pause_speech` | `switch` (bool) | Pause or resume (Shift on the PC) |
| `tone` | `hz`, `length` (ms), `left`, `right` (0–100) | NVDA beep (progress bars, browse mode, etc.) |
| `wave` | `fileName` | NVDA sound. The path is a **Windows** path on the remote PC; only the base name is usable |
| `display` | `cells` (list of integers 0–255) | Braille cells, one line, one dot pattern per cell |
| `set_clipboard_text` | `text` | The PC pushes its clipboard |
| `set_braille_info` | `name`, `numCells` | Sent by **other leaders**; NVDA responds by sending back its own info |
| `key` | | Keys sent by another leader: ignore |

### 2.5 Messages sent by the controller

| Type | Fields | Notes |
|---|---|---|
| `key` | `vk_code`, `extended`, `pressed`, `scan_code` | One message per key press and one per key release, modifiers included. **`scan_code` is ignored** by the PC (`localMachine.sendKey` passes `None`, and `MapVirtualKey` then recomputes it). As a result, `VK_PACKET` (Unicode) cannot be used |
| `set_braille_info` | `name`, `numCells` | Send on every `client_joined` from a follower. With `numCells` = 0, the PC never sends `display` |
| `braille_input` | see 2.7 | Gestures from the controller's braille display |
| `set_clipboard_text` | `text` | Push the clipboard |
| `send_SAS` | none | Ctrl+Alt+Del; only works if NVDA is installed on the PC with UIAccess and a suitable `SoftwareSASGeneration` policy |

### 2.6 `speak` format

`sequence` is a list mixing strings and `[ClassName, {attributes}]` pairs. Only subclasses of `SynthCommand` and `EndUtteranceCommand` are serialized (`serializer.py`); callback commands (`BeepCommand`, `WaveFileCommand`, `CallbackCommand`) are filtered out on the PC and arrive separately as `tone` and `wave`.

| Class | Attributes | Meaning |
|---|---|---|
| `IndexCommand` | `index` | Position marker (NVDA uses it to track the caret) |
| `CharacterModeCommand` | `state`, `isDefault` | Spelling mode |
| `LangChangeCommand` | `lang` (e.g. `fr_FR`), `isDefault` | Language switch |
| `BreakCommand` | `time` (ms) | Pause |
| `PitchCommand`, `RateCommand`, `VolumeCommand` | `_offset`, `_multiplier`, `isDefault` | Relative prosody |
| `PhonemeCommand` | `ipa`, `text` | IPA pronunciation with fallback text |
| `EndUtteranceCommand` | none | End of utterance |

A real example:

```json
{"type": "speak", "priority": 0, "origin": 3,
 "sequence": [["LangChangeCommand", {"lang": "fr_FR", "isDefault": false}],
              "Bureau  liste",
              ["IndexCommand", {"index": 12}],
              ["EndUtteranceCommand", {}]]}
```

A client must tolerate unknown classes (by ignoring them), just as NVDA does.

### 2.7 The keyboard, as the PC handles it

- The PC calls `SendInput` with `wVk` = `vk_code`, `wScan` = `MapVirtualKey(vk)`, the `KEYEVENTF_EXTENDEDKEY` flag if `extended` is set, and `KEYUP` if `pressed` is false (`input.py`).
- The relevant codes are in `vkCodes.py`. Key points:
  - Insert = `0x2D` with `extended` = true; non-extended `0x2D` = numpad Insert. Both act as the NVDA key by default.
  - Arrows, Home, End, Page Up/Down: `extended` is true. The same codes with `extended` false are the numpad keys (`numpad8`, `numpad4`, …), the ones used by NVDA's "desktop" layout.
  - `VK_NONE` = `0xFF`: NVDA sends it pressed then released as a "neutral key" to break up a key combination when switching back to local control (`releaseKeys`).
- Switching on the NVDA side: NVDA+Alt+Tab. When switching to remote control, the modifiers of the toggle combination are held back so that their release does not reach the PC; when switching back to local, every modifier still held down is released remotely.
- The controller sends **raw** keys: it is the PC that interprets combinations. The order must be: modifier down, key down, key up, modifier up.

### 2.8 Braille

- The PC only sends `display` if at least one leader has declared `numCells` > 0. It then shrinks its own width to the smallest declared width and forces a single line (`localMachine._handleFilterDisplayDimensions`).
- `cells`: integers 0–255, one per cell, bits = dots 1 to 8. The controller pads the right-hand side with zeros.
- Braille input (`braille_input`): a flat dictionary with `source`, `model`, `id` or `identifiers`, `dots`, `space`, `cellIndexes` (a list) plus `routingIndex` (for compatibility, a single cell), and `scriptPath` = `[module, class, script]`, which the PC resolves against its own scripts (`input.py`, `BrailleInputGesture.findScript`).

### 2.9 Miscellaneous

- URL scheme: `nvdaremote://host:port/?key=…&mode=master&insecure=true`. "Copy link" on the controlled PC already produces a link with `mode=master`, ready for the Mac.
- NVDA sounds (`source/waves/`): `connected`, `disconnected`, `controlled`, `controlling`, `clipboardPush`, `clipboardReceive`, `browseMode`, `focusMode`, `error`, etc. They are licensed under GPL v2+.
- Secure desktop (UAC, sign-in screen): handled entirely on the PC by a local bridge; nothing to do on the Mac.

---

## 3. What a macOS client can do, feature by feature

| Feature | Feasibility | How on macOS | Notes |
|---|---|---|---|
| Connecting to the public relay | Easy | `Network.framework` (`NWConnection` + TLS), system validation | Certificate verified as valid today |
| Connecting to an NVDA server | Easy | Same, plus `sec_protocol_options_set_verify_block`: SHA-256 of the DER certificate, trust prompt the first time, fingerprint remembered | Matches NVDA's behavior |
| Handshake, generated key, MOTD, client list, reconnection | Easy | `JSONSerialization`, line-based reading, 5-second retry loop | |
| Speech, option A | Easy | `AVSpeechSynthesizer`: system voices, independent of VoiceOver. `stopSpeaking(.immediate)` for `cancel`, `pauseSpeaking` for `pause_speech`, `rate`/`pitchMultiplier`/`volume` for prosody, voice selection by language for `LangChangeCommand`, spelling for `CharacterModeCommand`, the `AVSpeechSynthesisIPANotationAttribute` attribute for `PhonemeCommand`, the delegate for `IndexCommand` | Recommended default. Priority 2 = interrupt the current utterance |
| Speech, option B | Moderate | VoiceOver announcements (`NSAccessibility.post(… .announcementRequested …)`): spoken with VoiceOver's voice and rate | No interruption or pause, limited throughput, announcements may be coalesced. Useful as an option for people who want everything to go through VoiceOver |
| Speech, option C | Later | Embedded eSpeak NG (a C library that builds on macOS) | To give NVDA users their familiar eSpeak voice, at very high rates |
| Beeps (`tone`) | Easy | `AVAudioEngine` with a sine generator, left/right panning | |
| Sounds (`wave`) | Easy | Base name → bundled sound lookup table | Reusing NVDA's `.wav` files requires the GPL; otherwise, custom sounds |
| Two-way clipboard | Easy | `NSPasteboard` | |
| Ctrl+Alt+Del | Easy | A single message | Depends on the PC's configuration |
| Keyboard capture in remote mode | The big one | A `CGEventTap` (Input Monitoring permission) inserted at the head of the session: swallow every key, convert it, send it. Karabiner-Elements and nvdr do exactly this, so it is feasible, including for Command-Tab | See the design points below |
| Local/remote toggle shortcut | Easy | Global shortcut recognized inside the tap, outside capture | Must stay reliable in both modes |
| Braille output | Hard | See section 4.5 | VoiceOver owns the display |
| Braille input | Hard | Depends on output | |
| Controlled mode (the PC controls the Mac) | Out of scope | No public API for capturing VoiceOver's speech | Not a goal |
| `nvdaremote://` URLs | Easy | `CFBundleURLTypes` | |
| Remote mute, auto-connect at launch, recent connections list | Easy | Preferences | |

---

## 4. Design decisions to make

### 4.1 Speech

**Decided and measured on September 10, 2026; see [speech-measurements.md](speech-measurements.md).**
`AVSpeechSynthesizer` by default: up to 643 words per minute, effective
interruption in 40 milliseconds, seamless chaining between utterances. Embedding
eSpeak NG is not necessary. The app speaks NVDA's speech with its own synthesizer;
VoiceOver only announces the app's own status messages.

### 4.2 Keyboard capture: global or foreground window only

- **Global** (`CGEventTap`): works whatever app is in the foreground and can swallow keys before VoiceOver and the system see them. Requires the Input Monitoring permission (and Accessibility if we also want to post events). This is what nvdr does.
- **Local** (an `NSEvent` monitor while the app has focus): no permission needed, but VoiceOver intercepts its own commands and the system keeps Command-Tab, Command-Space, etc.

Recommendation: global, enabled only in "control the PC" mode.

### 4.3 Key mapping

**Measured on September 10, 2026; see [keyboard-measurements.md](keyboard-measurements.md).**
The measurements correct two points in this section: the tap must be installed at
the HID level rather than the session level, or VoiceOver consumes its own
commands; and keys must be mapped **by the character they produce**, not by
physical position, contrary to what is written below.


- Base mapping from kVK (physical position, `Carbon.HIToolbox`) → Windows VK, a table to write once.
- Modifiers: Control → Ctrl, Option → Alt, Command → Windows key (the Boot Camp / Parallels convention), with left and right distinguished (`0xA2`/`0xA3`, `0xA4`/`0xA5`, `0x5B`/`0x5C`).
- **NVDA key**: Macs have no Insert key. Provide a setting: fn, right Option, right Command or Caps Lock → extended `0x2D`. Caps Lock is tricky (its state toggles at the system level); fn is simple (`flagsChanged` event, code 63).
- **Numeric keypad**: send the Mac keypad digits as non-extended navigation keys (non-extended `0x26` = `numpad8`, etc.) so that NVDA's "desktop" layout works, or suggest using NVDA's "laptop" layout.
- **Keyboard layouts**: letters work fine (VK `0x41`–`0x5A` = the letter in the PC's current layout). Punctuation depends on the PC's layout (`VK_OEM_*`), and the AltGr key of a PC AZERTY keyboard does not exist on a Mac. ~~Recommendation: start with physical position.~~ **Corrected by measurement: keys are mapped by the character they produce without modifiers.** On the AZERTY Mac that was tested, key code 12 is named "ANSI_Q" but produces "a"; mapping by position would send `VK_Q` and the PC would type "q". This fully solves letters; digits and punctuation need a small table per layout.

### 4.4 Coexisting with VoiceOver

- In remote mode, the tap swallows everything and VoiceOver sees nothing: this is intended. An emergency exit is needed (the toggle shortcut, plus, for example, holding a key down for 2 seconds).
- A "mute when switching back to local" option, as in NVDA, so you don't hear the PC while working on the Mac.
- The app itself must be flawless with VoiceOver (connection window, settings, history).

### 4.5 Braille

Three tiers, in increasing order of difficulty:

1. **No braille** in v1: send `set_braille_info` with `numCells` = 0.
2. **Virtual display**: a window showing the received cells as Unicode braille characters (`U+2800` + the cell value). VoiceOver relays this text to the physical display. Little code; needs to be validated in practice (VoiceOver's translation and refresh behavior). No braille input or cursor routing.
3. **Direct driver**: open the display over USB HID (the "HID braille" standard, usage page 0x41) or Bluetooth via IOKit, when VoiceOver has not claimed it. Full output and input (dots, space, routing → `braille_input`). Existing direct-driver code, for example from a Brailliant project, could be reused here.

### 4.6 Technology

- A native Swift + AppKit (or SwiftUI) app with no external dependencies: `Network`, `AVFoundation`, `CoreGraphics`, `IOKit`.
- Before that, a command-line **Python prototype** could reuse NVDA's `serializer.py` and `transport.py` almost as is (removing `wx.CallAfter` and `SIO_KEEPALIVE_VALS`), speak through `say` or through `AVSpeechSynthesizer` via PyObjC, and validate the protocol end to end in an evening.

### 4.7 License

The protocol itself is not protected; a client written from scratch can use any license. Reusing NVDA's code or sounds puts the project under GPL v2 or later.

---

## 5. Proposed plan for the implementation

1. ~~**Phase 0, Python prototype**~~: dropped. Since Xcode 26 and Swift 6.3 are
   installed on the machine, the test benches are written directly in Swift, in
   the final stack, so nothing has to be rewritten. The speech bench is done
   (`spikes/speech-bench`); see [speech-measurements.md](speech-measurements.md).
2. **Phase 1, Swift app**: connection (relay and NVDA server with fingerprint), `AVSpeechSynthesizer` speech with `cancel` and priorities, beeps, sounds, clipboard, key generation, history, `nvdaremote://` URLs.
3. **Phase 2, keyboard**: global tap, toggle, kVK → VK table, configurable NVDA key, numeric keypad, French layout table.
4. **Phase 3, braille**: virtual display, then direct driver.

Test environment: a PC running NVDA 2025.1 or later with Remote Access enabled in its settings, either through `nvdaremote.com` or using "Host locally" on port 6837, with the `debugLog.remoteClient` log category enabled to see the messages.

---

## 6. Landmarks in the cloned code

All under `nvda/source/_remoteClient/`:

- `protocol.py`: message types, port 6837, URL prefix.
- `serializer.py`: line-by-line JSON, speech command encoding.
- `transport.py`: TLS socket, fingerprint, reconnection, `RelayTransport.onConnected` (handshake).
- `session.py`: `LeaderSession` (what the controller does) and `FollowerSession` (what the PC does), braille negotiation, `handleDecideExecuteGesture` (the `braille_input` format).
- `client.py`: `processKeyInput` (sending keys), `toggleRemoteKeyControl`, `releaseKeys`, certificate handling.
- `localMachine.py`: receiving on the controller side (`speak`, `display`, `beep`, `playWave`, `sendKey`, `sendSAS`).
- `input.py`: key injection on the PC (`SendInput`).
- `server.py`: built-in relay server, self-signed certificate, `ping`.
- `connectionInfo.py`: `nvdaremote://` URLs.
- `../vkCodes.py`: Windows key code table.
- `../../user_docs/en/userGuide.md`, "Remote Access" section: expected behavior from the user's point of view.

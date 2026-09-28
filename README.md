# NVDA Remote for macOS

A native macOS client for NVDA's **Remote Access** feature: control a Windows PC
running the NVDA screen reader from your Mac, and hear NVDA's speech and sounds on
the Mac.

The Mac is always the **controlling** computer ("leader", `master` in the protocol).
The reverse, a PC controlling the Mac, is out of scope: no public API gives access to
VoiceOver's speech.

The app is built for VoiceOver users first. It is available in English and French;
any other system language falls back to English.

## Features

- **Connection** through the public relay `nvdaremote.com`, another relay, or a PC
  that hosts the connection itself ("Host locally" in NVDA). Click an
  `nvdaremote://` link, such as the one from NVDA's "Copy link", to connect at once,
  or type a server and a key. Recent connections are remembered.
- **Speech**: NVDA's speech is spoken on the Mac with the system voices, with
  immediate interruption, language switching, and an adjustable rate in words per
  minute.
- **Beeps and sounds**: NVDA's beeps (progress bars, etc.) and sounds (browse mode,
  focus mode, errors…) play on the Mac.
- **Keyboard**: a global shortcut switches the Mac keyboard between the Mac and the
  PC. While controlling the PC, every key goes to the PC, VoiceOver commands
  included. Caps Lock, Right Option or fn can act as the NVDA key.
- **Clipboard**: text the PC sends arrives in the Mac clipboard; a global shortcut
  sends the Mac clipboard to the PC.
- **Menu bar and Dock**: the app lives in the menu bar, the Dock, or both. Closing
  the Connection window (Command-W) tucks the app away in the menu bar.
- **Braille**: while you control the PC, NVDA drives your braille display directly:
  its exact cells, routing keys, panning keys and braille keyboard, with the bindings
  of NVDA's HID braille driver. VoiceOver keeps running and gets the display back when
  you return to the Mac. Works with HID braille displays over USB or Bluetooth (such
  as the Brailliant BI X series). See [docs/braille-research.md](docs/braille-research.md).

Not yet available, or simplified compared with NVDA:

- Pitch, rate and volume commands embedded in NVDA's speech are ignored, and so are
  character mode (spelling) and IPA pronunciations, which fall back to their text.
- Speech with the "now" priority cuts the current speech without resuming it
  afterwards, and "next" is queued like normal speech.
- Braille works with HID braille displays only; displays that VoiceOver drives with a
  brand driver or over a Bluetooth serial link cannot be taken yet.

## Installing

Download the latest `NVDA-Remote-<version>.zip` from
[Releases](https://github.com/math65/nvdaremote-mac/releases/latest), unzip it and
move **NVDA Remote** to the Applications folder. The app is signed and notarized by
Apple.

The app then updates itself: it checks for new versions at launch and once a day,
and **Check for Updates…** in the app menu (or the menu bar icon) checks right away.
To try new features before everyone else, turn on **Receive beta versions** in
Settings, General.

To report a problem or send a suggestion, use **Help > Contact the Developer…**. A
problem report includes technical details (versions, settings, connection state),
never your channel key or your server address.

## Requirements

- macOS 14 Sonoma or later.
- On the PC: NVDA 2025.1 or later, with Remote Access enabled.
- To control the PC, the app must be allowed in System Settings, Privacy &
  Security, under both **Accessibility** and **Input Monitoring**. The app asks for
  them from its Keyboard settings.

## Using the app

1. On the PC, in NVDA's Remote Access menu, choose to allow this computer to be
   controlled, and note the key (or use "Copy link").
2. On the Mac, click the link, or open the Connection window, type the key (leave
   the server empty for `nvdaremote.com`) or paste the link, and press Return.
3. Press **Control-Command-R** to control the PC. Press it again to come back to the
   Mac. A high beep means the PC has the keyboard, a low beep means the Mac has it.
4. Press **Control-Command-C** to send the Mac clipboard to the PC.

Both shortcuts work from any app and can be changed in Settings.

### Keyboard mapping

| Mac | PC |
|---|---|
| Control | Ctrl |
| Option | Alt |
| Command | Windows key |
| Caps Lock (default), Right Option or fn | NVDA key (Insert) |
| Keypad | Numeric keypad, for NVDA's desktop layout |

Letters are mapped by the character they produce, so an AZERTY Mac drives an AZERTY
or QWERTY PC correctly. Digits work on the AZERTY top row with Shift. Punctuation
follows the PC keyboard layout chosen in Settings (French or US). Known limitation on
an AZERTY Mac: without Shift, the `!` key types `_` on the PC and the `§` key types
`-`, in exchange for reliable digits.

When Caps Lock is the NVDA key, it is remapped to F18 with `hidutil` only while the
PC is controlled, and restored when coming back to the Mac, when quitting, and at the
next launch after a crash. If other key remappings already exist, the app refuses to
overwrite them and asks for another NVDA key.

Coming back to the Mac releases every key still held on the PC. It also happens
automatically when the PC leaves or the connection drops. If the app ever froze,
macOS disables its keyboard tap and gives the keyboard back to the Mac.

## Building

Open `NVDARemote.xcodeproj` in Xcode 27 or later and run the **NVDARemote** scheme,
or build from the command line:

```bash
xcodebuild -project NVDARemote.xcodeproj -scheme NVDARemote -derivedDataPath build/DerivedData build
```

The app is not sandboxed, and cannot be: its keyboard capture swallows keys, which
needs an active event tap, and macOS only allows that with the Accessibility
permission. Sandboxed apps cannot get Accessibility: the prompt never shows and the
app cannot be added by hand in System Settings (measured on macOS 27; Apple DTS:
"It's not possible to use the Accessibility APIs from a sandboxed app",
<https://developer.apple.com/forums/thread/805556>). Input Monitoring alone only
allows listen-only taps. So the app is distributed with a Developer ID signature, the
hardened runtime and notarization, not through the Mac App Store.

Set your own development team in the project to sign it. With a stable signing
identity, the keyboard permissions survive rebuilds.

A signed and notarized build, ready to share:

```bash
scripts/build-release.sh
```

Publishing a release (GitHub release, Sparkle appcast in `docs/` served by GitHub
Pages) is `scripts/build-release.sh --release`, add `--beta` for the beta channel;
the whole procedure is in [.claude/skills/release/SKILL.md](.claude/skills/release/SKILL.md).
Builds made from a clone have no `App/AppBackendSecret.plist` (it is not versioned),
so Contact the Developer is hidden in them.

Tests of the protocol, keyboard mapping and sounds:

```bash
cd NVDARemote && swift test
```

The package also contains `nvdaremote`, a command-line tool that connects and speaks
NVDA's output without the keyboard, handy to debug the protocol:

```bash
cd NVDARemote && swift run -c release nvdaremote --verbose 'nvdaremote://nvdaremote.com:6837/?key=…&mode=master'
```

## Project layout

| Path | Contents |
|---|---|
| `NVDARemote.xcodeproj`, `App/`, `Config/` | The macOS app (SwiftUI) and its `Info.plist` additions |
| `NVDARemote/` | Swift package: the `RemoteCore` library (protocol, speech, sounds, keyboard) and the `nvdaremote` tool |
| `docs/` | Feasibility study and measurements; also the Sparkle appcast and release notes served by GitHub Pages |
| `spikes/` | Standalone benchmarks that validated speech and keyboard capture |
| `nvda/` | Reference clone of NVDA, not versioned |

To recreate the NVDA reference clone (the module of interest is
`nvda/source/_remoteClient/`):

```bash
git clone --depth 1 --filter=blob:none https://github.com/nvaccess/nvda.git nvda
```

## Documentation

| File | Contents |
|---|---|
| [docs/feasibility-study.md](docs/feasibility-study.md) | The protocol in detail, feature-by-feature feasibility, design decisions |
| [docs/speech-measurements.md](docs/speech-measurements.md) | `AVSpeechSynthesizer` measurements: latency, rate, interruption |
| [docs/keyboard-measurements.md](docs/keyboard-measurements.md) | `CGEventTap` measurements: tap level, Caps Lock, fn, layouts |
| [docs/braille-research.md](docs/braille-research.md) | How to show NVDA's cells on a VoiceOver braille display, and what reaches the app |

## License

GNU General Public License, version 2 or (at your option) any later version. The
project bundles NVDA's sounds, which are under the same license. See
[LICENSE.md](LICENSE.md).

NVDA is developed by [NV Access](https://www.nvaccess.org). This project is an
independent client and is not affiliated with NV Access.

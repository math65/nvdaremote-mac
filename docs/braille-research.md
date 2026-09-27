# Braille on macOS: research

Date: September 27, 2026. Scope: macOS 14 to macOS 27. Question: how can a Mac app
show NVDA's raw braille cells (`display` messages, one line, bits = dots 1 to 8) on
the braille display that VoiceOver drives, and send the display's keys back to NVDA?

Sources were read directly: Apple's documentation and SDK headers, the VoiceOver
resources installed on macOS 27, the source of liblouis, BRLTTY, nvdr and
orca-remote, and AppleVis threads.

## Verdict

**The app drives HID braille displays itself, while VoiceOver keeps running.**
VoiceOver's generic HID braille driver opens the display in shared mode. Opening it
once, directly with `kIOHIDOptionsTypeSeizeDevice`, makes the kernel set VoiceOver's
handle aside: its writes fail and its keys are dropped, but VoiceOver keeps running.
Closing the device, or the app dying, gives the display back, and VoiceOver drives it
again without any action. Validated on September 27, 2026 with a Brailliant BI 40X
over Bluetooth: exact cells, routing, panning, braille keyboard, and automatic return
to VoiceOver.

The first attempt failed for a subtle reason: the device was opened in shared mode
first (`IOHIDManagerOpen`), then with seize through the same client. IOHIDFamily
treats that as a repeated open ("Multiple opens from client") and returns success
without ever recording the seize. The device must be opened exactly once, with seize.
Source: `IOHIDDevice::handleOpen` and `IOHIDLibUserClient` in
<https://github.com/apple-oss-distributions/IOHIDFamily>.

Limits: displays that VoiceOver drives with a brand driver that seizes them itself
(HIMS, BrailleSense, older Brailliant, Papenmeier, Seika) cannot be taken, and
Bluetooth displays that are not HID (serial RFCOMM, such as older Focus Blue or Handy
Tech models) need a different driver.

The rest of this document records the earlier research, including the Unicode braille
fallback that was tried first and dropped: VoiceOver announced the element and spoke
the patterns.

## First approach: Unicode braille through VoiceOver

No public API writes raw cells to a VoiceOver-driven one-line display. The fallback
is to show NVDA's cells as Unicode braille (U+2800 + cell) in a text element that has
VoiceOver's focus. With most braille tables, VoiceOver then shows exactly NVDA's dots,
dots 7 and 8 included.

## Apple APIs

| API | What it does | Useful here? |
|---|---|---|
| `AXBrailleMap`, `AXBrailleMapRenderer` (macOS 12.1+) | Pin heights on **two-dimensional** displays such as the Dot Pad | No: nothing for one-line displays |
| `AXBrailleTranslator`, `AXBrailleTable` (macOS 26+) | Translates print text to Unicode braille and back | Only as a helper; it does not write to a display. Returned no tables from an unsigned command-line tool |
| `kAXBrailleLabelAttribute` (web `aria-braillelabel`) | A braille-specific label, still translated text | Not tested on native elements |
| VoiceOver AppleScript (`output`, `perform command`, `braille window`) | Announcements, VoiceOver commands, showing the on-screen Braille panel | Cannot read or write the display's cells |
| Braille Access (macOS 26) | Apple's note-taker mode | No third-party hook |

Sources: <https://developer.apple.com/documentation/accessibility/axbraillemap>,
<https://developer.apple.com/documentation/accessibility/axbrailletranslator>,
<https://support.apple.com/guide/voiceover/use-braille-access-vo16f725f5bc/mac>,
`/System/Library/CoreServices/VoiceOver.app/Contents/Resources/VoiceOver.sdef`.

## How VoiceOver shows Unicode braille

VoiceOver translates braille with liblouis 3.37.0
(`/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable`).
The shared liblouis file `braille-patterns.cti` maps each U+28xx character to its own
dots, and 159 of the 192 tables VoiceOver ships include it.

Translating "⠓⠑⠇⠇⠕ ⣿⡀⢀⠀" with Apple's own table files gave **exact dots, dots 7 and 8
included, even in 6-dot and contracted tables**, for: English US 6-dot, 8-dot and
contracted; UEB grades 1 and 2; French unified 6-dot, 8-dot and grade 2; German 8-dot.
Contracted tables may add an indicator before *following print text*, which does not
happen when the line holds only braille characters, with U+2800 for blank cells.

These tables print an escape such as `\x2813/` instead of the dots: English North
American Braille Computer Code, UK 8-dot, German `de-g0`, `de-g1` and `de-comp6`,
Polish, Slovenian, Norwegian and Persian 8-dot, Swedish, Vietnamese, IPA. The app
should warn users of these tables.

**Input.** VoiceOver ships an input table named "Braille Dot Patterns" ("Caractères
en braille" in French) that turns typed dots back into the exact U+28xx characters,
dots 7 and 8 included. Choosing it as the input table lets the app forward the exact
dots typed on the braille keyboard.

## Driving the display directly

VoiceOver's brand drivers for HIMS, BrailleSense, older Brailliant models, Papenmeier
and Seika open the device exclusively (`openWithSeize:`); HID-standard displays such
as the Brailliant BI 40X go through `GenericHID.brailledriver`, which opens them in
shared mode, hence the seize described above. There is no VoiceOver setting, command
or API to lend a display to an app. BRLTTY on macOS (<https://github.com/brltty/brltty>,
PRs #547 and #561) quits and relaunches VoiceOver to hand a display over, which this
project rejects. DriverKit brings nothing here: VoiceOver's braille server talks to the
device object directly.

## Prior art

No Mac client of NVDA Remote shows braille: nvdr and NVDARemoteCompanion declare
`noBraille`. On Linux, orca-remote (<https://github.com/serrebidev/orca-remote>)
shows NVDA's cells as Unicode braille through BrlAPI, the same idea as here.

## What reaches the app from the display

- **Routing keys** move the insertion point in a text field, so a routing press shows
  up as a selection change whose index is the cell. Source:
  <https://support.apple.com/guide/voiceover/use-the-router-keys-vo18520/mac>.
- **Braille keyboard** input is translated with the input table and inserted into the
  focused field.
- **Panning and chords** (space with dots) stay with VoiceOver. Commanders can assign
  display keys to custom commands such as "Run Shortcut…", which could open an
  `nvdaremote://` link; not yet confirmed.
- VoiceOver **Activities** can switch braille settings automatically for one app.
- The app cannot learn the display width from VoiceOver. The direct driver reads it
  from the display itself (the report count of its cell output).
- AppleVis reports occasional braille refresh problems in some contexts; latency was
  not measured anywhere.

## Experiments to run with a real display

1. A focused one-line field holding only U+28xx characters: exact dots in 6-dot,
   8-dot and contracted modes, dots 7 and 8 in 6-dot mode, label and status cells.
2. Refresh latency and reliability at NVDA's update rate.
3. Routing keys: index mapping, and whether restoring the caret makes VoiceOver pan.
4. Braille keyboard input with "Braille Dot Patterns": dots 7 and 8, space,
   backspace, Enter.
5. Whether an Activity can switch tables for the app automatically.
6. Whether a display key can run a Shortcut through a custom command.
7. Whether `AXBrailleTranslator` returns tables inside a signed app.
8. ~~Whether VoiceOver's generic HID driver lets another client open the device.~~
   Answered: it opens displays in shared mode, and a seize sets it aside (see Verdict).

# Keyboard capture measurements on macOS: CGEventTap

Date: September 10, 2026. macOS 26.6, Apple silicon Mac, **French AZERTY** keyboard.
Test bench: `spikes/keyboard-tap`, target `KeyboardTap`.
VoiceOver was running throughout all tests.

## Verdict

**Global keyboard capture works, provided the tap is installed at the HID level
rather than the session level.** This is the main finding of this bench.

At the session level, everything is captured and neutralized except VoiceOver
commands, which VoiceOver consumes before we see them. At the HID level, they come
through as well.

A sign that this is the right approach: the Clean Buddy app locks the entire
keyboard for cleaning, VoiceOver included.

Caps Lock, initially considered a blocker, is **solved** by remapping it to F18
with `hidutil`. See the corresponding section.

## Permissions

Both are required, and macOS refuses to create the tap without them:

| Permission | Purpose |
|---|---|
| Accessibility | Modify and swallow events |
| Input Monitoring | Observe events |

A practical pitfall: a command-line executable has no identity of its own as far as
macOS is concerned. Permissions are attached to the app that launches it, which is
the terminal. The final app will have its own identity and will request
permissions on its own behalf, which is the desired behavior.

## Interception level: the deciding factor

| Combination | `.cgSessionEventTap` tap | `.cghidEventTap` tap |
|---|---|---|
| Single letter | seen and swallowed | seen and swallowed |
| Command-Tab | seen and swallowed; the frontmost app did not change | seen and swallowed |
| Command-Space | seen and swallowed; Spotlight did not open | seen and swallowed |
| Control-Option-arrow (VoiceOver) | **arrow never received**, only the modifiers | **arrow received**, code 124 with option+ctrl |

At the session level, only the modifier changes came through: the arrow itself
was consumed by VoiceOver, which responded out loud. At the HID level, the arrow's
`keyDown` is present along with its modifiers.

Implication for the project: use `.cghidEventTap` with `.headInsertEventTap`.

The system never disabled the tap during the tests, neither through timeout nor
through user input, at either level.

## Caps Lock: solved

### The problem

Without special handling, the tap sees the key as a `flagsChanged` event on code
57, **but swallowing it does not stop it from taking effect**. The measurements
prove it: after a toggle, the next key produced an uppercase "A" instead of "a".
The lock state is managed below the tap, even at the HID level.

This is a blocker if we want to offer Caps Lock as the NVDA key, which is what
many laptop users are used to.

### The chosen solution: remapping the key with hidutil

`hidutil` rewrites the key mapping at the HID driver level, before anything else.
By redirecting Caps Lock to an unused function key, it becomes an ordinary key: no
more toggling, and the tap receives it normally.

```bash
hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
```

`0x700000039` is the HID usage code for Caps Lock, and `0x70000006D` is the one for F18.

To undo:

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

**Tested on September 10, 2026, with an unambiguous result.** After remapping, two
consecutive runs give:

```
keyDown  code 79 (F18)  no character  modifiers fn  swallowed
keyDown  code 12 (ANSI_Q)  character "a"  modifiers none  swallowed
```

The letter typed immediately afterward stays lowercase in both runs: the toggle
no longer happens at all. The key arrives as an ordinary F18, which the tap
swallows without difficulty.

Properties of this approach:

- No `sudo`, no driver, no kernel extension, no restart.
- Takes effect immediately, and is **reset on restart**. To make it permanent, a
  launch agent in `~/Library/LaunchAgents` can rerun the command at login.
- `hidutil` is just a command-line client for an IOKit API, so the app could apply
  and remove the remapping itself without depending on the system binary. To be
  verified at implementation time.

Side note: the F18 produced by the remapping also carries the `fn` flag, which
confirms once again that this flag must never be relied upon.

### Essential safeguards

While the remapping is active, the user has no Caps Lock **anywhere in the
system**. The app must therefore:

- only apply it if the user chooses Caps Lock as the NVDA key, after a clear
  explanation;
- remove it when the app quits, including after a crash, by checking and cleaning
  up on the next launch;
- remind the user that simply restarting the Mac puts everything back in order.

### The two other options, ruled out

- **`IOHIDSetModifierLockState`**: swallow the event, then force the lock state
  back. It works in theory, but it is an after-the-fact correction, with a risk of
  the LED flickering and a race between the event and the correction. Unnecessary,
  since remapping solves the problem at the source. Kept in reserve.
- **System Settings > Keyboard > Modifier Keys, "No Action"**: a manual step, and
  above all not tested here. The concern is that it might suppress the event
  entirely, which would make the key unusable for us rather than capturable. To be
  evaluated if needed.

## The fn key, and a serious pitfall

The fn key is seen, in two forms: a `keyDown` with code **179** (the Globe key on
recent Macs, missing from the Carbon constants) and a `flagsChanged` with code 63.

The pitfall: **arrow keys always carry the fn flag**, as well as the numeric
keypad flag. Raw log of a Right Arrow pressed on its own:

```
keyDown  code 124 (RightArrow)  modifiers fn+numpad
```

It is therefore impossible to detect an fn press by reading the flags: you have to
rely on key codes 179 and 63. A naive implementation that tested the fn flag would
think the NVDA key was held down whenever the user pressed an arrow key, which
would break all navigation.

The same reasoning applies to the numeric keypad flag, which cannot be used to
identify the actual numeric keypad.

## Keyboard layout: mapping must be done by character

Log from the machine's AZERTY keyboard:

| Key code | Position name | Character produced |
|---|---|---|
| 0 | ANSI_A | q |
| 6 | ANSI_Z | w |
| 12 | ANSI_Q | a |
| 13 | ANSI_W | z |

The macOS key code is **positional**: it identifies a physical location, named
after the US keyboard. The character produced depends on the layout active on the
Mac.

Windows virtual key codes, however, are not positional: on a French layout, the
key that produces "a" has the code `VK_A`, and NVDA recomputes the scan code itself
from the virtual key code, since it ignores the one we send.

**The mapping must therefore be based on the character produced, not on position.**
Example: key code 12 produces "a" on the Mac, we send `VK_A`, and the Windows
machine types "a", whether it uses AZERTY or QWERTY.

This **corrects the initial recommendation in the
[feasibility study](feasibility-study.md)**, which suggested starting with physical
position. That approach would have sent `VK_Q` when the user pressed the key
labeled "a".

Caveats to address at implementation time:

- The character must be read **without modifiers**. Otherwise Shift-A gives "A"
  and Option-A gives a composed character. The key has to be translated again with
  empty modifiers, using `UCKeyTranslate` or by clearing the flags on a copy of the
  event before reading its string.
- This rule is clean and sufficient for **letters**. For **digits and
  punctuation**, it is not enough: on AZERTY, the top row produces `&`, `é`, `"`,
  `'`, `(` without Shift, whereas Windows' `VK_1` to `VK_0` codes refer to those
  same keys. A small table per layout will be needed, written once for French and
  once for US English.
- Keys that produce no character (arrows, function keys, navigation keys) are
  mapped by key code, which poses no problem.

## What the code must do

1. Install the tap with `.cghidEventTap` and `.headInsertEventTap`, as a
   `.defaultTap` so that events can be swallowed.
2. Handle `tapDisabledByTimeout` and `tapDisabledByUserInput` by re-enabling the
   tap. This never happened here, but it occurs when the callback becomes slow.
3. Never read the fn flag to detect the fn key: use codes 179 and 63.
4. Derive the Windows virtual key code from the character produced without
   modifiers, falling back to a positional table for keys that produce no
   character.
5. If Caps Lock is chosen as the NVDA key, apply the `hidutil` remapping to F18
   on activation, remove it on quit, and clean up on the next launch if the app
   terminated abnormally.
6. Provide an emergency exit that is independent of everything else, because an
   active tap makes the machine unusable if something hangs. The bench uses
   three, all validated: Escape is always let through, a watchdog releases the
   keyboard after a timeout, and the tap is destroyed when the process dies.

## Remaining open question

At the HID level, the `keyDown` for Control-Option-arrow is indeed captured and
swallowed. It remains to be confirmed by ear that VoiceOver no longer reacts at
all in this mode, that is, that the event is actually swallowed and not merely
observed. The bench did mark the events as swallowed, but only listening can
prove it.

## Reproducing the measurements

Check permissions without capturing anything:

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap --check
```

Full guided test, seven steps, session level:

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap
```

Targeted VoiceOver test, four steps, HID level:

```bash
cd spikes/keyboard-tap && swift run -c release KeyboardTap --hid --voiceover
```

Instructions are given by voice, since VoiceOver is neutralized during capture.
Escape quits at any time.

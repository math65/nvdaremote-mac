# Speech measurements on macOS: AVSpeechSynthesizer

Date: September 10, 2026. macOS 26.6, Swift 6.3.3, Apple silicon Mac.
Voice used for measurements: Audrey (Enhanced), fr-FR.
Test benches: `spikes/speech-bench`, targets `SpeechBench` and `StopDiag`.

## Verdict

**AVSpeechSynthesizer is good enough.** There is no need to embed eSpeak NG in v1.
The system engine reaches 643 words per minute, cuts speech off in 40 milliseconds
and chains utterances with no audible gap. It feels on par with NVDA.

This removes the main risk identified in the [feasibility study](feasibility-study.md).

## Measurements

### Latency

| Measurement | Value |
|---|---|
| First utterance of the session, to first word | 449 ms |
| Subsequent utterance, to first word | 120 ms (median) |
| `speak` call to `didStart` | 2 ms (median) |
| Interrupt, then speak the next word | 40 ms (median), 53 ms worst case over 10 runs |
| Gap between two chained utterances | 1.8 ms (median), 6.7 ms cumulative over 5 fragments |
| Gap when switching voice from French to English | 5 to 44 ms |

Interrupting and resuming (40 ms) is faster than speaking after a period of
silence (120 ms) for a simple reason: in the first case, the audio engine is
already running. Hence the recommendation to keep it warm.

### Speech rate

| `rate` | Words per minute |
|---|---|
| 0.50 (default) | 177 |
| 0.60 | 279 |
| 0.70 | 378 |
| 0.85 | 519 |
| 1.00 (maximum) | 643 |
| 2.00 | 642, capped as expected |

The curve is linear above 0.5: roughly 100 more words per minute for each 0.1
step. A usable approximation: `wordsPerMinute ≈ 177 + (rate - 0.5) × 933`.

For reference, NVDA users with eSpeak commonly run between 300 and 450 words per
minute, which corresponds to a `rate` between 0.63 and 0.79. That leaves plenty of
headroom.

### Offline synthesis

`write(_:toBufferCallback:)` produces 2.12 seconds of audio in 0.236 seconds of
computation, i.e. 9 times faster than real time, at 22,050 Hz.

Implication: if playback through AVSpeechSynthesizer ever becomes a problem, we
can synthesize into buffers and handle audio output ourselves, which would allow
speech and NVDA beeps to be mixed cleanly in a single audio graph. This is not
needed today.

### Available voices

181 voices in total on this machine, 10 of them fr-FR: 1 enhanced (Audrey),
9 standard, no premium voices. French premium voices can be downloaded from
System Settings. Their latency has not been measured; see the open questions.

## What the code must do

1. **Do not use `didCancel`.** The callback is never called on macOS 26.
   `stopSpeaking(at:)` does return `true` and the audio stops, but it is `didFinish`
   that fires, about 6 ms after the call. All end-of-utterance logic must therefore
   rely on `didFinish` alone, without distinguishing a normal finish from an
   interruption. An automated test that waited for `didCancel` would hang forever:
   exactly the trap the first bench fell into.

2. **Warm up the engine when the session opens.** The very first utterance costs
   450 ms instead of 120. Speak a very short, or silent, utterance when the
   connection is established, so that the first output from the PC is immediate.

3. **One synthesizer for the whole session.** Ten interrupt-and-resume cycles on
   the same instance succeeded with no degradation. There is no need to recreate it.

4. **Mapping NVDA messages:**
   - `cancel` → `stopSpeaking(at: .immediate)`.
   - `speak` with `priority` 2 (now) → interrupt, then speak.
   - `speak` with `priority` 0 or 1 → enqueue; `AVSpeechSynthesizer` already chains
     utterances without gaps.
   - `pause_speech` → `pauseSpeaking` and `continueSpeaking`.

5. **Speech rate.** NVDA does not send an absolute rate: it is a local setting on
   the Mac. Provide a slider expressed in words per minute rather than as a `rate`
   value, which is more meaningful to a screen reader user, and apply the formula
   above. `RateCommand`, `PitchCommand` and `VolumeCommand` commands received in a
   sequence are relative: they apply on top of the base setting.

6. **Avoid `stopSpeaking(at: .word)`.** It lets the current word finish, which cost
   about 260 ms more in the measurements. Always use `.immediate`.

## Open questions

- Latency and maximum rate of premium and Siri voices have not been measured. This
  needs checking before offering them as the default: they sound better but may be
  slower to start, and here that matters more than sound quality.
- `AVSpeechUtterance.prefersAssistiveTechnologySettings` has not been tested. If it
  lets us inherit the rate set in VoiceOver, users would not have to set their
  speech rate twice. Worth exploring.
- The first spoken word is detected through the `willSpeakRangeOfSpeechString`
  callback, which is a close proxy for the first sound but not the sound itself.
  Absolute values should therefore be taken as orders of magnitude; comparisons
  between scenarios remain valid.

## Reproducing the measurements

```bash
cd spikes/speech-bench && swift run -c release SpeechBench
```

```bash
cd spikes/speech-bench && swift run -c release StopDiag
```

Both programs speak out loud; allow about a minute and a half for each.

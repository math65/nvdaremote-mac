// AVSpeechSynthesizer test bench for the NVDA Remote for macOS project.
//
// Goal: find out whether AVSpeechSynthesizer can keep up with NVDA.
// An NVDA user reads fast and interrupts speech constantly; if starting or
// interrupting speech costs too much, another engine will be needed.
//
// The bench speaks aloud: it is the only way to measure the real audio path.
// The pure synthesis test (T7) is the only silent one.
//
// The voice being measured is deliberately French (fr-FR, typically Audrey):
// it is the voice the project's users actually listen to, so its latency and
// speaking rate are what matter. The spoken sample texts are therefore kept in
// French so that they match the measured voice. Only the report is in English.

import AVFoundation
import Foundation

// MARK: - Utilities

/// Monotonic clock, in seconds.
func now() -> Double {
	Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// Runs the run loop until the condition is true.
/// Needed because delegate callbacks arrive on the main run loop.
@discardableResult
func pump(until predicate: () -> Bool, timeout: Double = 60) -> Bool {
	let deadline = now() + timeout
	while !predicate() {
		if now() >= deadline { return false }
		RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
	}
	return true
}

func sleepPumping(_ seconds: Double) {
	let deadline = now() + seconds
	pump(until: { now() >= deadline }, timeout: seconds + 1)
}

func ms(_ seconds: Double) -> String {
	String(format: "%.1f ms", seconds * 1000)
}

func median(_ values: [Double]) -> Double {
	guard !values.isEmpty else { return .nan }
	let sorted = values.sorted()
	let mid = sorted.count / 2
	return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func title(_ text: String) {
	print("")
	print(text)
	print(String(repeating: "-", count: text.count))
}

// MARK: - Recording delegate

final class Recorder: NSObject, AVSpeechSynthesizerDelegate {
	var didStartAt: Double?
	var didFinishAt: Double?
	var didCancelAt: Double?
	var firstRangeAt: Double?
	/// Finish then start timestamps, in order, to measure the gaps.
	var timeline: [(event: String, time: Double)] = []

	func reset() {
		didStartAt = nil
		didFinishAt = nil
		didCancelAt = nil
		firstRangeAt = nil
		timeline.removeAll()
	}

	func speechSynthesizer(_ synth: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
		let t = now()
		if didStartAt == nil { didStartAt = t }
		timeline.append(("start", t))
	}

	func speechSynthesizer(_ synth: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
		let t = now()
		didFinishAt = t
		timeline.append(("finish", t))
	}

	func speechSynthesizer(_ synth: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
		let t = now()
		didCancelAt = t
		timeline.append(("cancel", t))
	}

	func speechSynthesizer(
		_ synth: AVSpeechSynthesizer,
		willSpeakRangeOfSpeechString characterRange: NSRange,
		utterance: AVSpeechUtterance,
	) {
		if firstRangeAt == nil { firstRangeAt = now() }
	}
}

// MARK: - Setup

let synth = AVSpeechSynthesizer()
let recorder = Recorder()
synth.delegate = recorder

/// Reference text, in French to match the measured voice. The word count is
/// computed, never hard-coded.
let frenchSample = """
Le bureau contient une liste de trente éléments dont le premier est sélectionné \
et le dernier reste masqué derrière la fenêtre principale du navigateur
"""
let sampleWordCount = frenchSample.split(whereSeparator: { $0 == " " || $0 == "\n" }).count

func voice(forLanguage language: String, preferBest: Bool = true) -> AVSpeechSynthesisVoice? {
	let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
	guard !candidates.isEmpty else { return AVSpeechSynthesisVoice(language: language) }
	guard preferBest else { return candidates.first }
	func rank(_ v: AVSpeechSynthesisVoice) -> Int {
		switch v.quality {
		case .premium: return 3
		case .enhanced: return 2
		default: return 1
		}
	}
	return candidates.max(by: { rank($0) < rank($1) })
}

/// The measured voice: French on purpose, see the header comment.
let frenchVoice = voice(forLanguage: "fr-FR")
/// Only used by T6 to measure the cost of switching language.
let englishVoice = voice(forLanguage: "en-US")

func utterance(
	_ text: String,
	rate: Float = AVSpeechUtteranceDefaultSpeechRate,
	voice: AVSpeechSynthesisVoice? = frenchVoice,
) -> AVSpeechUtterance {
	let u = AVSpeechUtterance(string: text)
	u.rate = rate
	u.voice = voice
	// No silence added before or after: NVDA chains short utterances.
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	return u
}

/// Speaks and waits for the end. Returns (latency until didStart, latency until
/// the first spoken range, total duration measured from didStart to didFinish).
func speakAndWait(_ u: AVSpeechUtterance) -> (start: Double, firstRange: Double?, duration: Double)? {
	recorder.reset()
	let t0 = now()
	synth.speak(u)
	guard pump(until: { recorder.didFinishAt != nil }, timeout: 120),
	      let start = recorder.didStartAt,
	      let finish = recorder.didFinishAt
	else { return nil }
	let firstRange = recorder.firstRangeAt.map { $0 - t0 }
	return (start - t0, firstRange, finish - start)
}

// MARK: - Header

print("AVSpeechSynthesizer test bench — NVDA Remote for macOS project")
print("The bench will speak aloud for about a minute and a half.")
print("Reference text: \(sampleWordCount) words.")

// MARK: - T1: voice inventory

title("T1. Available voices")

let allVoices = AVSpeechSynthesisVoice.speechVoices()
print("Total on this machine: \(allVoices.count) voices.")

for language in ["fr-FR", "en-US"] {
	let voices = allVoices.filter { $0.language == language }
	let premium = voices.filter { $0.quality == .premium }.count
	let enhanced = voices.filter { $0.quality == .enhanced }.count
	let standard = voices.count - premium - enhanced
	print("\(language): \(voices.count) voices (\(premium) premium, \(enhanced) enhanced, \(standard) standard)")
}

if let v = frenchVoice {
	let quality: String
	switch v.quality {
	case .premium: quality = "premium"
	case .enhanced: quality = "enhanced"
	default: quality = "standard"
	}
	print("French voice selected for the measurements: \(v.name), \(quality) quality.")
} else {
	print("WARNING: no French voice found, the measurements will use the default voice.")
}

print("API rate bounds: min \(AVSpeechUtteranceMinimumSpeechRate), default \(AVSpeechUtteranceDefaultSpeechRate), max \(AVSpeechUtteranceMaximumSpeechRate).")

// MARK: - T2: startup latency

title("T2. Startup latency (speak call until first sound)")

var coldStart: Double?
var coldFirstRange: Double?
var warmStarts: [Double] = []
var warmFirstRanges: [Double] = []

for i in 0..<8 {
	guard let r = speakAndWait(utterance("Bonjour", rate: AVSpeechUtteranceDefaultSpeechRate)) else {
		print("Measurement \(i) failed.")
		continue
	}
	if i == 0 {
		coldStart = r.start
		coldFirstRange = r.firstRange
	} else {
		warmStarts.append(r.start)
		if let fr = r.firstRange { warmFirstRanges.append(fr) }
	}
	sleepPumping(0.1)
}

if let c = coldStart {
	print("Cold, first utterance of the session: didStart after \(ms(c))" +
		(coldFirstRange.map { ", first word spoken after \(ms($0))" } ?? "") + ".")
}
if !warmStarts.isEmpty {
	print("Warm, over \(warmStarts.count) measurements: median didStart \(ms(median(warmStarts))), " +
		"min \(ms(warmStarts.min()!)), max \(ms(warmStarts.max()!)).")
}
if !warmFirstRanges.isEmpty {
	print("Warm, first word spoken: median \(ms(median(warmFirstRanges))), " +
		"min \(ms(warmFirstRanges.min()!)), max \(ms(warmFirstRanges.max()!)).")
}

// MARK: - T3: interruption latency

title("T3. Interruption latency (immediate stopSpeaking until didCancel)")
print("This is the critical measurement: NVDA sends cancel on every keystroke.")

var cancelLatencies: [Double] = []

for _ in 0..<8 {
	recorder.reset()
	synth.speak(utterance(frenchSample, rate: AVSpeechUtteranceDefaultSpeechRate))
	guard pump(until: { recorder.didStartAt != nil }, timeout: 10) else { continue }
	sleepPumping(0.35)
	let t0 = now()
	synth.stopSpeaking(at: .immediate)
	guard pump(until: { recorder.didCancelAt != nil || recorder.didFinishAt != nil }, timeout: 10) else { continue }
	if let c = recorder.didCancelAt {
		cancelLatencies.append(c - t0)
	}
	sleepPumping(0.1)
}

if cancelLatencies.isEmpty {
	print("No measurement: stopSpeaking did not trigger didCancel.")
} else {
	print("Over \(cancelLatencies.count) measurements: median \(ms(median(cancelLatencies))), " +
		"min \(ms(cancelLatencies.min()!)), max \(ms(cancelLatencies.max()!)).")
	print("Caveat: didCancel reports the stop on the API side. Audio already in the")
	print("output buffer may keep playing a few more milliseconds, not measurable here.")
}

// MARK: - T4: actual speaking rate

title("T4. Actual speaking rate in words per minute")
print("NVDA with eSpeak commonly runs between 300 and 450 words per minute.")

var wpmByRate: [(rate: Float, wpm: Double, duration: Double)] = []

for rate in [Float(0.5), 0.6, 0.7, 0.85, 1.0] {
	guard let r = speakAndWait(utterance(frenchSample, rate: rate)) else {
		print("rate \(rate): measurement failed.")
		continue
	}
	let wpm = Double(sampleWordCount) / r.duration * 60
	wpmByRate.append((rate, wpm, r.duration))
	print(String(format: "rate %.2f: %.0f words/minute (%.2f s for %d words)",
		rate, wpm, r.duration, sampleWordCount))
	sleepPumping(0.1)
}

// Is the rate really capped beyond the advertised maximum?
if let r = speakAndWait(utterance(frenchSample, rate: 2.0)) {
	let wpm = Double(sampleWordCount) / r.duration * 60
	print(String(format: "rate 2.00 (beyond the maximum): %.0f words/minute — %@",
		wpm,
		wpmByRate.last.map { abs($0.wpm - wpm) < 15 ? "capped as expected" : "NOT capped" } ?? "no reference"))
}

if let best = wpmByRate.max(by: { $0.wpm < $1.wpm }) {
	print(String(format: "Maximum achievable rate: %.0f words/minute.", best.wpm))
	if best.wpm < 300 {
		print("VERDICT: below what NVDA users are used to. An embedded eSpeak-ng will be needed.")
	} else if best.wpm < 400 {
		print("VERDICT: fine for everyday use, borderline for fast readers.")
	} else {
		print("VERDICT: sufficient, including for fast readers.")
	}
}

// MARK: - T5: chaining without gaps

title("T5. Gaps between chained utterances")
print("NVDA sends a burst of short speak messages; cumulative gaps become noticeable.")

recorder.reset()
// Short French fragments, typical of what NVDA announces, spoken by the measured voice.
let fragments = ["Documents", "dossier", "trois éléments", "liste", "Bureau"]
for f in fragments {
	synth.speak(utterance(f, rate: 0.6))
}
pump(until: { recorder.timeline.filter { $0.event == "finish" }.count >= fragments.count }, timeout: 60)

var gaps: [Double] = []
var lastFinish: Double?
for entry in recorder.timeline {
	if entry.event == "finish" {
		lastFinish = entry.time
	} else if entry.event == "start", let lf = lastFinish {
		gaps.append(entry.time - lf)
		lastFinish = nil
	}
}

if gaps.isEmpty {
	print("No gap measured.")
} else {
	print("Over \(gaps.count) transitions: median \(ms(median(gaps))), " +
		"min \(ms(gaps.min()!)), max \(ms(gaps.max()!)).")
	let total = gaps.reduce(0, +)
	print("Total over \(fragments.count) fragments: \(ms(total)).")
}

// MARK: - T6: language switch

title("T6. Cost of a language switch")
print("NVDA's speak message carries LangChangeCommand items mid-sequence.")

if englishVoice == nil {
	print("No English voice available, test skipped.")
} else {
	recorder.reset()
	synth.speak(utterance("Bonjour", rate: 0.6, voice: frenchVoice))
	synth.speak(utterance("Hello", rate: 0.6, voice: englishVoice))
	synth.speak(utterance("Bonjour", rate: 0.6, voice: frenchVoice))
	pump(until: { recorder.timeline.filter { $0.event == "finish" }.count >= 3 }, timeout: 60)

	var switchGaps: [Double] = []
	var previousFinish: Double?
	for entry in recorder.timeline {
		if entry.event == "finish" {
			previousFinish = entry.time
		} else if entry.event == "start", let pf = previousFinish {
			switchGaps.append(entry.time - pf)
			previousFinish = nil
		}
	}
	if switchGaps.isEmpty {
		print("No transition measured.")
	} else {
		print("Gaps on voice switches: " +
			switchGaps.map { ms($0) }.joined(separator: ", ") + ".")
	}
}

// MARK: - T7: pure synthesis, no playback

title("T7. Pure synthesis to buffer, no audio playback")
print("If this path is much faster, we can handle playback ourselves and take")
print("back control over latency and mixing with the beeps.")

do {
	var bufferCount = 0
	var frameCount: AVAudioFrameCount = 0
	var sampleRate: Double = 0
	var finished = false
	let t0 = now()

	let writeSynth = AVSpeechSynthesizer()
	writeSynth.write(utterance(frenchSample, rate: 1.0)) { buffer in
		guard let pcm = buffer as? AVAudioPCMBuffer else { return }
		if pcm.frameLength == 0 {
			finished = true
			return
		}
		bufferCount += 1
		frameCount += pcm.frameLength
		sampleRate = pcm.format.sampleRate
	}

	if pump(until: { finished }, timeout: 30) {
		let elapsed = now() - t0
		let audioSeconds = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
		print(String(format: "Synthesized %.2f s of audio in %.3f s of compute (%d buffers, %.0f Hz).",
			audioSeconds, elapsed, bufferCount, sampleRate))
		if audioSeconds > 0 {
			print(String(format: "That is %.0f times real time.", audioSeconds / elapsed))
		}
		if audioSeconds > 0 {
			let wpm = Double(sampleWordCount) / audioSeconds * 60
			print(String(format: "Rate of the produced signal: %.0f words/minute.", wpm))
		}
	} else {
		print("Synthesis to buffer did not complete within the time limit.")
	}
}

// MARK: - End

title("End of bench")
print("Report complete.")

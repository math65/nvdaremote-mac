// Speech interruption diagnostic.
//
// The main bench got no measurement at all for stopSpeaking: didCancel was
// never called. Yet it is the most heavily used function in the project, since
// NVDA sends a cancel message on every keystroke. This program closely observes
// what actually happens.
//
// The real question is not "which delegate callback fires" but "how quickly
// does the sound stop and the next speech start". That is what scenario 3
// measures, the only one that matters to the user.
//
// The measured voice is deliberately French (fr-FR, typically Audrey), the
// voice the project's users actually listen to. The spoken test phrases are
// therefore kept in French so that they match that voice. Only the report is
// in English.

import AVFoundation
import Foundation

func now() -> Double {
	Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

@discardableResult
func pump(until predicate: () -> Bool, timeout: Double = 30) -> Bool {
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
	let s = values.sorted()
	let m = s.count / 2
	return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}

func title(_ text: String) {
	print("")
	print(text)
	print(String(repeating: "-", count: text.count))
}

/// Time origin, reset before each scenario.
var origin = now()

final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
	var events: [(name: String, time: Double, text: String)] = []
	var verbose = true

	func record(_ name: String, _ utterance: AVSpeechUtterance) {
		let t = now()
		events.append((name, t, utterance.speechString))
		if verbose {
			print(String(format: "  %+8.1f ms  %@  \"%@\"", (t - origin) * 1000, name, utterance.speechString))
		}
	}

	func reset() { events.removeAll() }

	func first(_ name: String) -> Double? {
		events.first(where: { $0.name == name })?.time
	}

	func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { record("didStart ", u) }
	func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { record("didFinish", u) }
	func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { record("didCancel", u) }
	func speechSynthesizer(_ s: AVSpeechSynthesizer, didPause u: AVSpeechUtterance) { record("didPause ", u) }
	func speechSynthesizer(_ s: AVSpeechSynthesizer, didContinue u: AVSpeechUtterance) { record("didCont. ", u) }

	func speechSynthesizer(
		_ s: AVSpeechSynthesizer,
		willSpeakRangeOfSpeechString characterRange: NSRange,
		utterance: AVSpeechUtterance,
	) {
		let t = now()
		events.append(("willSpeak", t, utterance.speechString))
		if verbose {
			let text = utterance.speechString as NSString
			let word = characterRange.location + characterRange.length <= text.length
				? text.substring(with: characterRange) : "?"
			print(String(format: "  %+8.1f ms  willSpeak  \"%@\"", (t - origin) * 1000, word))
		}
	}
}

let delegate = Delegate()

/// The measured voice: the best available French voice, on purpose (see the
/// header comment).
func bestFrenchVoice() -> AVSpeechSynthesisVoice? {
	let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "fr-FR" }
	func rank(_ v: AVSpeechSynthesisVoice) -> Int {
		switch v.quality {
		case .premium: return 3
		case .enhanced: return 2
		default: return 1
		}
	}
	return candidates.max(by: { rank($0) < rank($1) }) ?? AVSpeechSynthesisVoice(language: "fr-FR")
}

let frenchVoice = bestFrenchVoice()
/// A deliberately long French utterance, so it can be interrupted midway
/// before it finishes on its own.
let longText = """
Ceci est un énoncé volontairement long qui doit durer assez longtemps pour que \
l'on puisse l'interrompre en plein milieu sans qu'il ait eu le temps de se terminer \
tout seul avant la fin de la mesure
"""

func makeUtterance(_ text: String, rate: Float = 0.5) -> AVSpeechUtterance {
	let u = AVSpeechUtterance(string: text)
	u.rate = rate
	u.voice = frenchVoice
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	return u
}

print("Interruption diagnostic — AVSpeechSynthesizer")
print("Voice used: \(frenchVoice?.name ?? "default")")

// MARK: - Scenario 1: which callback stopSpeaking triggers

title("Scenario 1. Which callbacks does stopSpeaking(.immediate) trigger?")

do {
	let synth = AVSpeechSynthesizer()
	synth.delegate = delegate
	delegate.reset()
	delegate.verbose = true
	origin = now()

	synth.speak(makeUtterance(longText))
	pump(until: { delegate.first("didStart ") != nil }, timeout: 10)
	sleepPumping(0.5)

	print("  isSpeaking before the stop: \(synth.isSpeaking), isPaused: \(synth.isPaused)")
	origin = now()
	let returned = synth.stopSpeaking(at: .immediate)
	print("  stopSpeaking(.immediate) returned: \(returned)")

	sleepPumping(1.0)
	print("  isSpeaking after the stop: \(synth.isSpeaking)")

	let names = Set(delegate.events.map { $0.name.trimmingCharacters(in: .whitespaces) })
	print("  Callbacks observed: \(names.sorted().joined(separator: ", "))")
	if !names.contains("didCancel") {
		print("  FINDING: didCancel is never called on this version of macOS.")
	}
}

// MARK: - Scenario 2: the same with a fresh synthesizer and .word

title("Scenario 2. stopSpeaking(.word) on a fresh synthesizer")

do {
	let synth = AVSpeechSynthesizer()
	synth.delegate = delegate
	delegate.reset()
	delegate.verbose = true
	origin = now()

	synth.speak(makeUtterance(longText))
	pump(until: { delegate.first("didStart ") != nil }, timeout: 10)
	sleepPumping(0.5)

	origin = now()
	let returned = synth.stopSpeaking(at: .word)
	print("  stopSpeaking(.word) returned: \(returned)")
	sleepPumping(1.0)
	print("  isSpeaking after the stop: \(synth.isSpeaking)")
}

// MARK: - Scenario 3: the measurement that really matters

title("Scenario 3. Perceived latency: cut off, then chain a new utterance")
print("This is exactly what NVDA does: cancel, then speak the next text.")
print("Measured from the stopSpeaking call until the first word actually spoken.")

do {
	var latencies: [Double] = []
	var stopReturns: [Bool] = []
	delegate.verbose = false

	for i in 0..<10 {
		let synth = AVSpeechSynthesizer()
		synth.delegate = delegate
		delegate.reset()

		synth.speak(makeUtterance(longText))
		guard pump(until: { delegate.first("didStart ") != nil }, timeout: 10) else {
			print("  Iteration \(i): the long utterance did not start.")
			continue
		}
		sleepPumping(0.4)

		let t0 = now()
		stopReturns.append(synth.stopSpeaking(at: .immediate))
		delegate.reset()
		synth.speak(makeUtterance("Coupé", rate: 0.55))

		guard pump(until: { delegate.first("willSpeak") != nil }, timeout: 10),
		      let spoken = delegate.first("willSpeak")
		else {
			print("  Iteration \(i): the new utterance was never spoken.")
			continue
		}
		latencies.append(spoken - t0)
		pump(until: { delegate.first("didFinish") != nil }, timeout: 10)
		sleepPumping(0.1)
	}

	if latencies.isEmpty {
		print("  No usable measurement.")
	} else {
		print(String(format: "  Over %d measurements: median %@, min %@, max %@.",
			latencies.count,
			ms(median(latencies)),
			ms(latencies.min()!),
			ms(latencies.max()!)))
		let ok = stopReturns.allSatisfy { $0 }
		print("  stopSpeaking returned true every time: \(ok).")
		let m = median(latencies)
		if m < 0.08 {
			print("  VERDICT: imperceptible, on par with how NVDA feels.")
		} else if m < 0.15 {
			print("  VERDICT: acceptable, slight delay noticeable when reading fast.")
		} else {
			print("  VERDICT: too slow, we will have to handle audio playback ourselves.")
		}
	}
}

// MARK: - Scenario 4: reusing a synthesizer after a stop

title("Scenario 4. Does a synthesizer remain usable after a stop?")
print("If a synthesizer goes dead after stopSpeaking, a new one would have to be")
print("created on every interruption, which would be costly hundreds of times a minute.")

do {
	let synth = AVSpeechSynthesizer()
	synth.delegate = delegate
	delegate.verbose = false
	var successes = 0
	var latencies: [Double] = []

	for _ in 0..<10 {
		delegate.reset()
		synth.speak(makeUtterance(longText))
		guard pump(until: { delegate.first("didStart ") != nil }, timeout: 10) else { break }
		sleepPumping(0.3)

		let t0 = now()
		synth.stopSpeaking(at: .immediate)
		delegate.reset()
		synth.speak(makeUtterance("Suivant", rate: 0.55))
		if pump(until: { delegate.first("willSpeak") != nil }, timeout: 5),
		   let spoken = delegate.first("willSpeak") {
			successes += 1
			latencies.append(spoken - t0)
		}
		pump(until: { delegate.first("didFinish") != nil }, timeout: 5)
		sleepPumping(0.05)
	}

	print("  \(successes) successful chainings out of 10 with the same synthesizer.")
	if !latencies.isEmpty {
		print(String(format: "  Median latency: %@.", ms(median(latencies))))
	}
	if successes == 10 {
		print("  FINDING: a single synthesizer is enough for the whole session.")
	} else {
		print("  FINDING: the synthesizer degrades, plan to recycle it.")
	}
}

title("End of diagnostic")

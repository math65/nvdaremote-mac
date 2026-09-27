// Diagnostic de l'interruption de parole.
//
// Le banc principal n'a obtenu aucune mesure sur stopSpeaking : didCancel n'a
// jamais été appelé. Or c'est la fonction la plus sollicitée du projet, NVDA
// envoyant un message cancel à chaque frappe. Ce programme observe finement
// ce qui se passe réellement.
//
// La vraie question n'est pas « quel rappel du délégué est déclenché » mais
// « en combien de temps le son s'arrête et la parole suivante démarre ».
// C'est ce que mesure le scénario 3, le seul qui compte pour l'utilisateur.

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

/// Origine des temps, repositionnée avant chaque scénario.
var origin = now()

final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
	var events: [(name: String, time: Double, text: String)] = []
	var verbose = true

	func record(_ name: String, _ utterance: AVSpeechUtterance) {
		let t = now()
		events.append((name, t, utterance.speechString))
		if verbose {
			print(String(format: "  %+8.1f ms  %@  « %@ »", (t - origin) * 1000, name, utterance.speechString))
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
			print(String(format: "  %+8.1f ms  willSpeak  « %@ »", (t - origin) * 1000, word))
		}
	}
}

let delegate = Delegate()

func voiceFR() -> AVSpeechSynthesisVoice? {
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

let fr = voiceFR()
let longText = """
Ceci est un énoncé volontairement long qui doit durer assez longtemps pour que \
l'on puisse l'interrompre en plein milieu sans qu'il ait eu le temps de se terminer \
tout seul avant la fin de la mesure
"""

func makeUtterance(_ text: String, rate: Float = 0.5) -> AVSpeechUtterance {
	let u = AVSpeechUtterance(string: text)
	u.rate = rate
	u.voice = fr
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	return u
}

print("Diagnostic de l'interruption — AVSpeechSynthesizer")
print("Voix utilisée : \(fr?.name ?? "défaut")")

// MARK: - Scénario 1 : quel rappel est déclenché par stopSpeaking

title("Scénario 1. Quels rappels déclenche stopSpeaking(.immediate) ?")

do {
	let synth = AVSpeechSynthesizer()
	synth.delegate = delegate
	delegate.reset()
	delegate.verbose = true
	origin = now()

	synth.speak(makeUtterance(longText))
	pump(until: { delegate.first("didStart ") != nil }, timeout: 10)
	sleepPumping(0.5)

	print("  isSpeaking avant l'arrêt : \(synth.isSpeaking), isPaused : \(synth.isPaused)")
	origin = now()
	let returned = synth.stopSpeaking(at: .immediate)
	print("  stopSpeaking(.immediate) a renvoyé : \(returned)")

	sleepPumping(1.0)
	print("  isSpeaking après l'arrêt : \(synth.isSpeaking)")

	let names = Set(delegate.events.map { $0.name.trimmingCharacters(in: .whitespaces) })
	print("  Rappels observés : \(names.sorted().joined(separator: ", "))")
	if !names.contains("didCancel") {
		print("  CONSTAT : didCancel n'est jamais appelé sur cette version de macOS.")
	}
}

// MARK: - Scénario 2 : la même chose avec un synthétiseur neuf et .word

title("Scénario 2. stopSpeaking(.word) sur un synthétiseur neuf")

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
	print("  stopSpeaking(.word) a renvoyé : \(returned)")
	sleepPumping(1.0)
	print("  isSpeaking après l'arrêt : \(synth.isSpeaking)")
}

// MARK: - Scénario 3 : la mesure qui compte vraiment

title("Scénario 3. Latence perçue : couper puis enchaîner sur un nouvel énoncé")
print("C'est exactement ce que fait NVDA : cancel, puis speak du texte suivant.")
print("On mesure de l'appel à stopSpeaking jusqu'au premier mot réellement prononcé.")

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
			print("  Itération \(i) : l'énoncé long n'a pas démarré.")
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
			print("  Itération \(i) : le nouvel énoncé n'a jamais été prononcé.")
			continue
		}
		latencies.append(spoken - t0)
		pump(until: { delegate.first("didFinish") != nil }, timeout: 10)
		sleepPumping(0.1)
	}

	if latencies.isEmpty {
		print("  Aucune mesure exploitable.")
	} else {
		print(String(format: "  Sur %d mesures : médiane %@, min %@, max %@.",
			latencies.count,
			ms(median(latencies)),
			ms(latencies.min()!),
			ms(latencies.max()!)))
		let ok = stopReturns.allSatisfy { $0 }
		print("  stopSpeaking a renvoyé true à chaque fois : \(ok).")
		let m = median(latencies)
		if m < 0.08 {
			print("  VERDICT : imperceptible, équivalent au ressenti NVDA.")
		} else if m < 0.15 {
			print("  VERDICT : acceptable, léger retard perceptible en lecture rapide.")
		} else {
			print("  VERDICT : trop lent, il faudra gérer nous-mêmes la lecture audio.")
		}
	}
}

// MARK: - Scénario 4 : réutiliser un synthétiseur après un arrêt

title("Scénario 4. Un synthétiseur reste-t-il utilisable après un arrêt ?")
print("Si un synthétiseur devient inerte après stopSpeaking, il faudra en recréer un")
print("à chaque interruption, ce qui coûterait cher des centaines de fois par minute.")

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

	print("  \(successes) enchaînements réussis sur 10 avec le même synthétiseur.")
	if !latencies.isEmpty {
		print(String(format: "  Latence médiane : %@.", ms(median(latencies))))
	}
	if successes == 10 {
		print("  CONSTAT : un seul synthétiseur suffit pour toute la session.")
	} else {
		print("  CONSTAT : le synthétiseur se dégrade, prévoir un recyclage.")
	}
}

title("Fin du diagnostic")

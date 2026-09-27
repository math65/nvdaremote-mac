// Banc d'essai AVSpeechSynthesizer pour le projet NVDA Remote macOS.
//
// Objectif : savoir si AVSpeechSynthesizer peut tenir le rythme de NVDA.
// Un utilisateur de NVDA lit vite et coupe la parole en permanence ; si le
// démarrage ou l'interruption coûtent trop cher, il faudra un autre moteur.
//
// Le banc parle à voix haute : c'est le seul moyen de mesurer le vrai chemin
// audio. Le test de synthèse pure (T7) est le seul à rester silencieux.

import AVFoundation
import Foundation

// MARK: - Utilitaires

/// Horloge monotone, en secondes.
func now() -> Double {
	Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// Fait tourner la boucle d'exécution jusqu'à ce que la condition soit vraie.
/// Nécessaire car les rappels du délégué arrivent sur la boucle principale.
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

// MARK: - Délégué enregistreur

final class Recorder: NSObject, AVSpeechSynthesizerDelegate {
	var didStartAt: Double?
	var didFinishAt: Double?
	var didCancelAt: Double?
	var firstRangeAt: Double?
	/// Horodatages de fin puis de début, dans l'ordre, pour mesurer les blancs.
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

// MARK: - Préparation

let synth = AVSpeechSynthesizer()
let recorder = Recorder()
synth.delegate = recorder

/// Texte de référence. Le nombre de mots est calculé, jamais codé en dur.
let sampleFR = """
Le bureau contient une liste de trente éléments dont le premier est sélectionné \
et le dernier reste masqué derrière la fenêtre principale du navigateur
"""
let sampleWordCount = sampleFR.split(whereSeparator: { $0 == " " || $0 == "\n" }).count

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

let frVoice = voice(forLanguage: "fr-FR")
let enVoice = voice(forLanguage: "en-US")

func utterance(
	_ text: String,
	rate: Float = AVSpeechUtteranceDefaultSpeechRate,
	voice: AVSpeechSynthesisVoice? = frVoice,
) -> AVSpeechUtterance {
	let u = AVSpeechUtterance(string: text)
	u.rate = rate
	u.voice = voice
	// Pas de silence ajouté avant ou après : NVDA enchaîne des énoncés courts.
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	return u
}

/// Parle et attend la fin. Renvoie (latence jusqu'à didStart, latence jusqu'au
/// premier intervalle parlé, durée totale mesurée de didStart à didFinish).
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

// MARK: - En-tête

print("Banc d'essai AVSpeechSynthesizer — projet NVDA Remote macOS")
print("Le banc va parler à voix haute pendant environ une minute et demie.")
print("Texte de référence : \(sampleWordCount) mots.")

// MARK: - T1 : inventaire des voix

title("T1. Voix disponibles")

let allVoices = AVSpeechSynthesisVoice.speechVoices()
print("Total sur cette machine : \(allVoices.count) voix.")

for language in ["fr-FR", "en-US"] {
	let voices = allVoices.filter { $0.language == language }
	let premium = voices.filter { $0.quality == .premium }.count
	let enhanced = voices.filter { $0.quality == .enhanced }.count
	let standard = voices.count - premium - enhanced
	print("\(language) : \(voices.count) voix (\(premium) premium, \(enhanced) améliorées, \(standard) standard)")
}

if let v = frVoice {
	let quality: String
	switch v.quality {
	case .premium: quality = "premium"
	case .enhanced: quality = "améliorée"
	default: quality = "standard"
	}
	print("Voix française retenue pour les mesures : \(v.name), qualité \(quality).")
} else {
	print("ATTENTION : aucune voix française trouvée, les mesures utiliseront la voix par défaut.")
}

print("Bornes de débit de l'API : min \(AVSpeechUtteranceMinimumSpeechRate), défaut \(AVSpeechUtteranceDefaultSpeechRate), max \(AVSpeechUtteranceMaximumSpeechRate).")

// MARK: - T2 : latence de démarrage

title("T2. Latence de démarrage (appel de speak jusqu'au premier son)")

var coldStart: Double?
var coldFirstRange: Double?
var warmStarts: [Double] = []
var warmFirstRanges: [Double] = []

for i in 0..<8 {
	guard let r = speakAndWait(utterance("Bonjour", rate: AVSpeechUtteranceDefaultSpeechRate)) else {
		print("Mesure \(i) échouée.")
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
	print("À froid, premier énoncé de la session : didStart après \(ms(c))" +
		(coldFirstRange.map { ", premier mot parlé après \(ms($0))" } ?? "") + ".")
}
if !warmStarts.isEmpty {
	print("À chaud, sur \(warmStarts.count) mesures : didStart médian \(ms(median(warmStarts))), " +
		"min \(ms(warmStarts.min()!)), max \(ms(warmStarts.max()!)).")
}
if !warmFirstRanges.isEmpty {
	print("À chaud, premier mot parlé : médian \(ms(median(warmFirstRanges))), " +
		"min \(ms(warmFirstRanges.min()!)), max \(ms(warmFirstRanges.max()!)).")
}

// MARK: - T3 : latence d'interruption

title("T3. Latence d'interruption (stopSpeaking immédiat jusqu'à didCancel)")
print("C'est la mesure critique : NVDA envoie cancel à chaque frappe.")

var cancelLatencies: [Double] = []

for _ in 0..<8 {
	recorder.reset()
	synth.speak(utterance(sampleFR, rate: AVSpeechUtteranceDefaultSpeechRate))
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
	print("Aucune mesure : stopSpeaking n'a pas déclenché didCancel.")
} else {
	print("Sur \(cancelLatencies.count) mesures : médiane \(ms(median(cancelLatencies))), " +
		"min \(ms(cancelLatencies.min()!)), max \(ms(cancelLatencies.max()!)).")
	print("Réserve : didCancel signale l'arrêt côté API. Le son déjà dans le tampon")
	print("de sortie peut continuer quelques millisecondes de plus, non mesurable ici.")
}

// MARK: - T4 : débit réel

title("T4. Débit réel en mots par minute")
print("NVDA avec eSpeak tourne couramment entre 300 et 450 mots par minute.")

var wpmByRate: [(rate: Float, wpm: Double, duration: Double)] = []

for rate in [Float(0.5), 0.6, 0.7, 0.85, 1.0] {
	guard let r = speakAndWait(utterance(sampleFR, rate: rate)) else {
		print("rate \(rate) : mesure échouée.")
		continue
	}
	let wpm = Double(sampleWordCount) / r.duration * 60
	wpmByRate.append((rate, wpm, r.duration))
	print(String(format: "rate %.2f : %.0f mots/minute (%.2f s pour %d mots)",
		rate, wpm, r.duration, sampleWordCount))
	sleepPumping(0.1)
}

// Le débit est-il bien plafonné au-delà du maximum annoncé ?
if let r = speakAndWait(utterance(sampleFR, rate: 2.0)) {
	let wpm = Double(sampleWordCount) / r.duration * 60
	print(String(format: "rate 2.00 (au-delà du maximum) : %.0f mots/minute — %@",
		wpm,
		wpmByRate.last.map { abs($0.wpm - wpm) < 15 ? "plafonné comme prévu" : "NON plafonné" } ?? "sans référence"))
}

if let best = wpmByRate.max(by: { $0.wpm < $1.wpm }) {
	print(String(format: "Débit maximum atteignable : %.0f mots/minute.", best.wpm))
	if best.wpm < 300 {
		print("VERDICT : en dessous des habitudes des utilisateurs NVDA. eSpeak-ng embarqué à prévoir.")
	} else if best.wpm < 400 {
		print("VERDICT : correct pour un usage courant, juste pour les lecteurs rapides.")
	} else {
		print("VERDICT : suffisant, y compris pour les lecteurs rapides.")
	}
}

// MARK: - T5 : enchaînement sans blanc

title("T5. Blancs entre énoncés enchaînés")
print("NVDA envoie une rafale de messages speak courts ; les blancs cumulés se voient.")

recorder.reset()
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
	print("Aucun blanc mesuré.")
} else {
	print("Sur \(gaps.count) transitions : médiane \(ms(median(gaps))), " +
		"min \(ms(gaps.min()!)), max \(ms(gaps.max()!)).")
	let total = gaps.reduce(0, +)
	print("Cumul sur \(fragments.count) fragments : \(ms(total)).")
}

// MARK: - T6 : changement de langue

title("T6. Coût d'un changement de langue")
print("Le message speak de NVDA porte des LangChangeCommand en cours de séquence.")

if enVoice == nil {
	print("Pas de voix anglaise disponible, test ignoré.")
} else {
	recorder.reset()
	synth.speak(utterance("Bonjour", rate: 0.6, voice: frVoice))
	synth.speak(utterance("Hello", rate: 0.6, voice: enVoice))
	synth.speak(utterance("Bonjour", rate: 0.6, voice: frVoice))
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
		print("Aucune transition mesurée.")
	} else {
		print("Blancs lors des changements de voix : " +
			switchGaps.map { ms($0) }.joined(separator: ", ") + ".")
	}
}

// MARK: - T7 : synthèse pure, sans lecture

title("T7. Synthèse pure vers tampon, sans lecture audio")
print("Si ce chemin est bien plus rapide, on peut gérer nous-mêmes la lecture")
print("et reprendre la main sur la latence et le mélange avec les bips.")

do {
	var bufferCount = 0
	var frameCount: AVAudioFrameCount = 0
	var sampleRate: Double = 0
	var finished = false
	let t0 = now()

	let writeSynth = AVSpeechSynthesizer()
	writeSynth.write(utterance(sampleFR, rate: 1.0)) { buffer in
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
		print(String(format: "Synthèse de %.2f s d'audio en %.3f s de calcul (%d tampons, %.0f Hz).",
			audioSeconds, elapsed, bufferCount, sampleRate))
		if audioSeconds > 0 {
			print(String(format: "Soit %.0f fois le temps réel.", audioSeconds / elapsed))
		}
		if audioSeconds > 0 {
			let wpm = Double(sampleWordCount) / audioSeconds * 60
			print(String(format: "Débit du signal produit : %.0f mots/minute.", wpm))
		}
	} else {
		print("La synthèse vers tampon n'a pas abouti dans le délai imparti.")
	}
}

// MARK: - Fin

title("Fin du banc")
print("Rapport terminé.")

// Banc d'essai de la capture clavier globale — projet NVDA Remote macOS.
//
// Questions auxquelles ce programme répond :
//   1. Quelle permission macOS est réellement exigée pour avaler des touches ?
//   2. Un CGEventTap voit-il, et peut-il avaler, Commande+Tab et Commande+Espace ?
//   3. Voit-il les commandes de VoiceOver (Contrôle+Option+flèche) ?
//   4. Que devient Verrouillage majuscules ? Et la touche fn ?
//   5. Quel est le lien entre code de touche physique et caractère produit,
//      sur un clavier azerty ? C'est la base de la table vers les codes Windows.
//
// Pendant la phase de capture, VoiceOver ne répond plus : le tap avale tout.
// Les consignes sont donc données à la voix, et le rapport n'est affiché
// qu'une fois le clavier relâché.
//
// Sorties de secours : Échap passe toujours et termine le test ; un chien de
// garde relâche le clavier au bout de 90 secondes quoi qu'il arrive ; et tuer
// le processus détruit le tap avec lui.

import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

// MARK: - Utilitaires

func now() -> Double {
	Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

@discardableResult
func pump(until predicate: () -> Bool, timeout: Double) -> Bool {
	let deadline = now() + timeout
	while !predicate() {
		if now() >= deadline { return false }
		RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
	}
	return true
}

func title(_ text: String) {
	print("")
	print(text)
	print(String(repeating: "-", count: text.count))
}

// MARK: - Noms des touches physiques (positions ANSI)

/// Noms de position, tels que définis par Carbon. Sur un clavier azerty, la
/// touche à la position « ANSI Q » produit un « a » : c'est précisément l'écart
/// que ce banc met en évidence.
let keyNames: [Int64: String] = [
	0: "ANSI_A", 1: "ANSI_S", 2: "ANSI_D", 3: "ANSI_F", 4: "ANSI_H",
	5: "ANSI_G", 6: "ANSI_Z", 7: "ANSI_X", 8: "ANSI_C", 9: "ANSI_V",
	11: "ANSI_B", 12: "ANSI_Q", 13: "ANSI_W", 14: "ANSI_E", 15: "ANSI_R",
	16: "ANSI_Y", 17: "ANSI_T", 18: "ANSI_1", 19: "ANSI_2", 20: "ANSI_3",
	21: "ANSI_4", 22: "ANSI_6", 23: "ANSI_5", 24: "ANSI_Equal", 25: "ANSI_9",
	26: "ANSI_7", 27: "ANSI_Minus", 28: "ANSI_8", 29: "ANSI_0",
	30: "ANSI_RightBracket", 31: "ANSI_O", 32: "ANSI_U", 33: "ANSI_LeftBracket",
	34: "ANSI_I", 35: "ANSI_P", 36: "Return", 37: "ANSI_L", 38: "ANSI_J",
	39: "ANSI_Quote", 40: "ANSI_K", 41: "ANSI_Semicolon", 42: "ANSI_Backslash",
	43: "ANSI_Comma", 44: "ANSI_Slash", 45: "ANSI_N", 46: "ANSI_M",
	47: "ANSI_Period", 48: "Tab", 49: "Space", 50: "ANSI_Grave", 51: "Delete",
	53: "Escape", 54: "RightCommand", 55: "Command", 56: "Shift",
	57: "CapsLock", 58: "Option", 59: "Control", 60: "RightShift",
	61: "RightOption", 62: "RightControl", 63: "Function (fn)", 64: "F17",
	65: "KeypadDecimal", 67: "KeypadMultiply", 69: "KeypadPlus",
	71: "KeypadClear", 75: "KeypadDivide", 76: "KeypadEnter",
	78: "KeypadMinus", 81: "KeypadEquals", 82: "Keypad0", 83: "Keypad1",
	84: "Keypad2", 85: "Keypad3", 86: "Keypad4", 87: "Keypad5", 88: "Keypad6",
	89: "Keypad7", 91: "Keypad8", 92: "Keypad9", 96: "F5", 97: "F6", 98: "F7",
	99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
	109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
	116: "PageUp", 117: "ForwardDelete", 118: "F4", 119: "End", 120: "F2",
	121: "PageDown", 122: "F1", 123: "LeftArrow", 124: "RightArrow",
	125: "DownArrow", 126: "UpArrow",
	// Touche Globe / fn des Mac récents, absente des constantes Carbon.
	179: "Globe (fn)",
	// Cibles habituelles d'un remapping de Verrouillage majuscules par hidutil.
	79: "F18", 80: "F19", 90: "F20",
]

func keyName(_ code: Int64) -> String {
	keyNames[code] ?? "inconnu(\(code))"
}

func describeFlags(_ flags: CGEventFlags) -> String {
	var parts: [String] = []
	if flags.contains(.maskCommand) { parts.append("cmd") }
	if flags.contains(.maskAlternate) { parts.append("option") }
	if flags.contains(.maskControl) { parts.append("ctrl") }
	if flags.contains(.maskShift) { parts.append("maj") }
	if flags.contains(.maskAlphaShift) { parts.append("VERRMAJ") }
	if flags.contains(.maskSecondaryFn) { parts.append("fn") }
	if flags.contains(.maskNumericPad) { parts.append("pavénum") }
	return parts.isEmpty ? "aucun" : parts.joined(separator: "+")
}

// MARK: - Enregistrement des événements

struct Captured {
	let time: Double
	let type: String
	let keyCode: Int64
	let characters: String
	let flags: CGEventFlags
	let isRepeat: Bool
	let swallowed: Bool
}

final class Recorder {
	var events: [Captured] = []
	var escapePressed = false
	var tapDisabledCount = 0
	/// Fenêtre courante de l'étape en cours, pour trier les événements ensuite.
	var stepStart: Double = 0

	func eventsSinceStepStart() -> [Captured] {
		events.filter { $0.time >= stepStart }
	}
}

let recorder = Recorder()

// MARK: - Le tap

/// Le rappel est un pointeur de fonction C : pas de capture possible, d'où
/// l'usage d'objets globaux.
func tapCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
	// Le système désactive un tap trop lent ou perturbé : il faut le relancer.
	if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
		recorder.tapDisabledCount += 1
		if let tap = globalTap {
			CGEvent.tapEnable(tap: tap, enable: true)
		}
		return Unmanaged.passUnretained(event)
	}

	let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
	let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

	var characters = ""
	if type == .keyDown || type == .keyUp {
		var length = 0
		var buffer = [UniChar](repeating: 0, count: 8)
		event.keyboardGetUnicodeString(
			maxStringLength: 8,
			actualStringLength: &length,
			unicodeString: &buffer,
		)
		if length > 0 {
			characters = String(utf16CodeUnits: buffer, count: length)
		}
	}

	let typeName: String
	switch type {
	case .keyDown: typeName = "keyDown"
	case .keyUp: typeName = "keyUp"
	case .flagsChanged: typeName = "flagsChanged"
	default: typeName = "autre(\(type.rawValue))"
	}

	// Sortie de secours : Échap n'est jamais avalée et termine le test.
	let isEscape = (keyCode == 53)
	if isEscape, type == .keyDown {
		recorder.escapePressed = true
	}

	recorder.events.append(Captured(
		time: now(),
		type: typeName,
		keyCode: keyCode,
		characters: characters,
		flags: event.flags,
		isRepeat: isRepeat,
		swallowed: !isEscape,
	))

	// Tout est avalé sauf Échap.
	return isEscape ? Unmanaged.passUnretained(event) : nil
}

var globalTap: CFMachPort?

// MARK: - Parole pour guider le test

let synth = AVSpeechSynthesizer()

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

let frenchVoice = voiceFR()
var speechDone = false

final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
	func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
		speechDone = true
	}
}

let speechDelegate = SpeechDelegate()
synth.delegate = speechDelegate

func say(_ text: String, rate: Float = 0.55, waitForEnd: Bool = true) {
	let u = AVSpeechUtterance(string: text)
	u.rate = rate
	u.voice = frenchVoice
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	speechDone = false
	synth.speak(u)
	if waitForEnd {
		pump(until: { speechDone }, timeout: 30)
	}
}

// MARK: - Vérification des permissions

title("Permissions")

let processName = ProcessInfo.processInfo.processName
let parentDescription = NSWorkspace.shared.frontmostApplication?.localizedName ?? "inconnue"
print("Processus : \(processName)")
print("Application au premier plan au lancement : \(parentDescription)")
print("")
print("Rappel important : un exécutable en ligne de commande n'a pas d'identité propre")
print("pour macOS. Les autorisations se rattachent à l'application qui le lance, donc")
print("au terminal utilisé. C'est ce terminal qu'il faudra autoriser, pas ce binaire.")
print("L'app finale, elle, aura sa propre identité et demandera pour son compte.")
print("")

let axTrusted = AXIsProcessTrusted()
print("Accessibilité (permet de MODIFIER et d'avaler des événements) : " +
	(axTrusted ? "accordée" : "NON accordée"))

let listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
let listenText: String
switch listenAccess {
case kIOHIDAccessTypeGranted: listenText = "accordée"
case kIOHIDAccessTypeDenied: listenText = "refusée"
default: listenText = "jamais demandée"
}
print("Surveillance de l'entrée (permet d'OBSERVER les événements) : \(listenText)")

let mask =
	(1 << CGEventType.keyDown.rawValue) |
	(1 << CGEventType.keyUp.rawValue) |
	(1 << CGEventType.flagsChanged.rawValue)

// Deux niveaux d'interception possibles :
//   .cgSessionEventTap : au niveau de la session, après les processus privilégiés.
//   .cghidEventTap     : au plus près du matériel, donc AVANT VoiceOver.
// VoiceOver ayant confisqué Contrôle+Option+flèche au niveau session, le mode
// HID sert à savoir si le contourner est possible sans pilote DriverKit.
let useHIDTap = CommandLine.arguments.contains("--hid")
print("Niveau d'interception demandé : " + (useHIDTap ? "HID (au plus bas)" : "session"))

let tap = CGEvent.tapCreate(
	tap: useHIDTap ? .cghidEventTap : .cgSessionEventTap,
	place: .headInsertEventTap,
	options: .defaultTap,
	eventsOfInterest: CGEventMask(mask),
	callback: tapCallback,
	userInfo: nil,
)

guard let tap else {
	print("")
	print("ÉCHEC : impossible de créer le tap.")
	print("")
	print("C'est le résultat attendu si l'autorisation manque, et c'est déjà une")
	print("réponse utile : macOS exige bien une permission explicite pour avaler")
	print("des touches, elle ne peut pas être contournée.")
	print("")
	print("Pour continuer, ouvre Réglages Système, Confidentialité et sécurité,")
	print("puis ajoute ton terminal dans Accessibilité, et dans Surveillance de l'entrée.")
	print("Il faut ensuite relancer le terminal pour que la permission prenne effet.")
	exit(1)
}

globalTap = tap
print("")
print("Tap créé avec succès : l'autorisation nécessaire est donc déjà en place.")

// Passe de vérification seule : on n'active jamais le tap, donc le clavier
// n'est jamais capturé. Sert à savoir où l'on en est sans bloquer la machine.
if CommandLine.arguments.contains("--check") {
	print("")
	print("Mode vérification : le tap n'a pas été activé, ton clavier est intact.")
	print("Relance sans --check pour dérouler le test guidé.")
	exit(0)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Chien de garde : le clavier est relâché au bout de 90 secondes quoi qu'il arrive.
let watchdogDeadline = now() + 90

func watchdogExpired() -> Bool {
	now() >= watchdogDeadline
}

// MARK: - Test guidé

struct Step {
	let spoken: String
	let label: String
	let seconds: Double
	/// Vérifier si l'application au premier plan a changé (preuve qu'une
	/// combinaison système comme Commande+Tab est passée malgré nous).
	let checkFrontmost: Bool
}

/// Test ciblé : la flèche est-elle capturable seule, et VoiceOver la
/// confisque-t-il quand elle est combinée à Contrôle+Option ?
let voiceOverSteps: [Step] = [
	Step(spoken: "Test un. Appuie sur la flèche droite, toute seule.",
	     label: "Flèche droite seule", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test deux. Appuie sur contrôle option flèche droite, ensemble.",
	     label: "Contrôle+Option+Flèche droite", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test trois. Appuie sur contrôle option flèche gauche.",
	     label: "Contrôle+Option+Flèche gauche", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test quatre. Appuie sur verrouillage majuscules, puis sur la lettre A.",
	     label: "Verr. maj. puis lettre", seconds: 6, checkFrontmost: false),
]

/// Test dédié : Verrouillage majuscules bascule-t-il encore l'état du système ?
/// La lettre tapée juste après dit tout : « a » signifie que la bascule est
/// neutralisée, « A » qu'elle a eu lieu malgré nous.
let capsLockSteps: [Step] = [
	Step(spoken: "Test un. Appuie sur verrouillage majuscules, puis tape la lettre A.",
	     label: "Verr. maj. puis A, premier essai", seconds: 6, checkFrontmost: false),
	Step(spoken: "Test deux. Appuie encore sur verrouillage majuscules, puis tape la lettre A.",
	     label: "Verr. maj. puis A, second essai", seconds: 6, checkFrontmost: false),
]

let fullSteps: [Step] = [
	Step(spoken: "Test un. Appuie sur la touche A.",
	     label: "Touche simple", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test deux. Appuie sur commande tab.",
	     label: "Commande+Tab", seconds: 5, checkFrontmost: true),
	Step(spoken: "Test trois. Appuie sur commande espace.",
	     label: "Commande+Espace (Spotlight)", seconds: 5, checkFrontmost: true),
	Step(spoken: "Test quatre. Appuie sur contrôle option flèche droite, une commande VoiceOver.",
	     label: "Contrôle+Option+Flèche (VoiceOver)", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test cinq. Appuie sur verrouillage majuscules, deux fois.",
	     label: "Verrouillage majuscules", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test six. Appuie sur la touche fonction, en bas à gauche.",
	     label: "Touche fn", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test sept. Tape les lettres A, Q, W et Z, l'une après l'autre.",
	     label: "Disposition du clavier", seconds: 7, checkFrontmost: false),
]

let useVoiceOverSteps = CommandLine.arguments.contains("--voiceover")
let steps: [Step] = CommandLine.arguments.contains("--capslock")
	? capsLockSteps
	: (useVoiceOverSteps ? voiceOverSteps : fullSteps)

var results: [(step: Step, events: [Captured], frontBefore: String, frontAfter: String)] = []

say("Attention, je vais capturer le clavier dans cinq secondes. " +
	"VoiceOver ne répondra plus pendant le test. " +
	"\(steps.count) consignes vont suivre, une par touche à essayer. " +
	"Échap termine tout à n'importe quel moment. Prépare tes mains.")

let readyDeadline = now() + 5
pump(until: { now() >= readyDeadline }, timeout: 6)

say("Le clavier est maintenant capturé.")

for step in steps {
	if recorder.escapePressed || watchdogExpired() { break }

	let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "inconnue"
	say(step.spoken)

	recorder.stepStart = now()
	let deadline = now() + step.seconds
	pump(until: { now() >= deadline || recorder.escapePressed || watchdogExpired() },
	     timeout: step.seconds + 2)

	let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "inconnue"
	results.append((step, recorder.eventsSinceStepStart(), frontBefore, frontAfter))
}

// MARK: - Libération du clavier

CGEvent.tapEnable(tap: tap, enable: false)
CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
globalTap = nil

say("Clavier relâché. VoiceOver revient. Le rapport est affiché dans le terminal.")

// MARK: - Rapport

title("Résultats du test guidé")

if recorder.escapePressed {
	print("Test interrompu par Échap. Les étapes atteintes sont ci-dessous.")
}
if watchdogExpired() {
	print("Chien de garde déclenché : le clavier a été relâché après 90 secondes.")
}

for result in results {
	print("")
	print("• \(result.step.label)")
	let keyDowns = result.events.filter { $0.type == "keyDown" && !$0.isRepeat }
	let flagChanges = result.events.filter { $0.type == "flagsChanged" }

	if result.events.isEmpty {
		print("  AUCUN événement capturé. Le tap n'a pas vu cette touche.")
	} else {
		for e in keyDowns {
			let charText = e.characters.isEmpty ? "aucun caractère" : "caractère « \(e.characters) »"
			print("  keyDown  code \(e.keyCode) (\(keyName(e.keyCode)))  \(charText)  " +
				"modificateurs \(describeFlags(e.flags))  " +
				(e.swallowed ? "avalé" : "LAISSÉ PASSER"))
		}
		for e in flagChanges {
			print("  flagsChanged  code \(e.keyCode) (\(keyName(e.keyCode)))  " +
				"état \(describeFlags(e.flags))  " +
				(e.swallowed ? "avalé" : "LAISSÉ PASSER"))
		}
		let others = result.events.count - keyDowns.count - flagChanges.count
		if others > 0 {
			print("  plus \(others) événement(s) de relâchement ou de répétition.")
		}
	}

	if result.step.checkFrontmost {
		if result.frontBefore == result.frontAfter {
			print("  Application au premier plan inchangée (\(result.frontAfter)) : " +
				"la combinaison système a bien été neutralisée.")
		} else {
			print("  ATTENTION : premier plan passé de \(result.frontBefore) à \(result.frontAfter). " +
				"La combinaison est passée malgré le tap.")
		}
	}
}

title("Synthèse")

let allEvents = recorder.events
print("Événements capturés au total : \(allEvents.count).")
print("Désactivations du tap par le système : \(recorder.tapDisabledCount).")

let distinctKeys = Set(allEvents.filter { $0.type == "keyDown" }.map { $0.keyCode })
print("Touches distinctes vues : \(distinctKeys.count).")

let capsLockSeen = allEvents.contains { $0.keyCode == 57 }
print("Verrouillage majuscules vu par le tap : \(capsLockSeen ? "oui" : "non")")

let fnSeen = allEvents.contains { $0.keyCode == 63 || $0.flags.contains(.maskSecondaryFn) }
print("Touche fn vue par le tap : \(fnSeen ? "oui" : "non")")

title("Correspondance position vers caractère")
print("Utile pour la table vers les codes de touches Windows : le code est")
print("positionnel, le caractère dépend de la disposition active sur le Mac.")

var mapping: [Int64: String] = [:]
for e in allEvents where e.type == "keyDown" && !e.characters.isEmpty {
	mapping[e.keyCode] = e.characters
}
if mapping.isEmpty {
	print("Aucune correspondance relevée.")
} else {
	for (code, char) in mapping.sorted(by: { $0.key < $1.key }) {
		print("  code \(code) nommé \(keyName(code)) produit « \(char) »")
	}
}

title("Fin du banc clavier")

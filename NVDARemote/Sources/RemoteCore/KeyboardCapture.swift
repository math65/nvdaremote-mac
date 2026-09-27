import ApplicationServices
import CoreGraphics
import Foundation

/// Combinaison de touches du Mac, par exemple le raccourci de bascule entre Mac et PC.
public struct KeyShortcut: Codable, Equatable, Sendable {
	public var keyCode: UInt16
	public var control = false
	public var option = false
	public var command = false
	public var shift = false

	public init(keyCode: UInt16, control: Bool = false, option: Bool = false, command: Bool = false, shift: Bool = false) {
		self.keyCode = keyCode
		self.control = control
		self.option = option
		self.command = command
		self.shift = shift
	}

	/// Contrôle+Commande+R (code 15, même position en azerty et en qwerty).
	public static let defaultToggle = KeyShortcut(keyCode: 15, control: true, command: true)

	/// Un raccourci doit comporter Contrôle, Option ou Commande, sinon il gênerait la frappe.
	public var isUsable: Bool { control || option || command }

	public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
		keyCode == self.keyCode
			&& flags.contains(.maskControl) == control
			&& flags.contains(.maskAlternate) == option
			&& flags.contains(.maskCommand) == command
			&& flags.contains(.maskShift) == shift
	}

	/// Nom lisible, par exemple « Ctrl+Cmd+R ».
	public func displayName(characters: KeyTranslator.Characters?) -> String {
		var parts: [String] = []
		if control { parts.append("Ctrl") }
		if option { parts.append("Option") }
		if shift { parts.append("Maj") }
		if command { parts.append("Cmd") }
		parts.append(Self.keyName(keyCode, characters: characters))
		return parts.joined(separator: "+")
	}

	private static func keyName(_ keyCode: UInt16, characters: KeyTranslator.Characters?) -> String {
		let names: [UInt16: String] = [
			MacKeyCode.returnKey: "Retour", MacKeyCode.tab: "Tab", MacKeyCode.space: "Espace",
			MacKeyCode.delete: "Effacement", MacKeyCode.escape: "Échap", 117: "Suppression",
			115: "Début", 119: "Fin", 116: "Page précédente", 121: "Page suivante",
			123: "Flèche gauche", 124: "Flèche droite", 125: "Flèche bas", 126: "Flèche haut",
			122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
			98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
		]
		if let name = names[keyCode] {
			return name
		}
		if let plain = characters?.plain, !plain.isEmpty {
			return plain.uppercased()
		}
		return "touche \(keyCode)"
	}
}

/// Capture globale du clavier par `CGEventTap`, et envoi des touches au PC en mode distant.
///
/// Suit docs/mesures-clavier.md : tap au niveau HID, faute de quoi VoiceOver confisque
/// ses propres commandes ; réactivation si le système désactive le tap ; touche fn
/// reconnue par son code et jamais par son drapeau, que les flèches portent aussi.
///
/// En mode local, seul le raccourci de bascule est intercepté. En mode distant, toutes
/// les touches sont avalées et envoyées au PC, sauf les relâchements de touches qu'on
/// n'a pas envoyées enfoncées : ceux-là reviennent au Mac, qui a vu l'appui.
@MainActor
public final class KeyboardCapture {
	public var toggleShortcut = KeyShortcut.defaultToggle
	/// À couper pendant qu'on enregistre un nouveau raccourci, pour qu'il arrive à la fenêtre.
	public var isToggleEnabled = true
	public var translator = KeyTranslator()
	/// Appelé quand l'utilisateur tape le raccourci de bascule.
	public var onToggle: (() -> Void)?
	/// Touche à envoyer au PC, enfoncée ou relâchée.
	public var onKey: ((WindowsKey, Bool) -> Void)?

	public private(set) var isRemote = false
	public var isRunning: Bool { tap != nil }

	public let layout = MacKeyboardLayout()
	private var tap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?
	/// Touches envoyées enfoncées au PC, dans l'ordre d'appui.
	private var sentDown: [WindowsKey] = []
	/// Touche du raccourci de bascule dont on a avalé l'appui : son relâchement doit l'être aussi.
	private var swallowedKeyUps: Set<UInt16> = []

	public init() {}

	// MARK: - Autorisations

	/// Accessibilité pour avaler les événements, Surveillance de l'entrée pour les observer.
	public static var hasPermissions: Bool {
		AXIsProcessTrusted() && CGPreflightListenEventAccess()
	}

	/// Déclenche les demandes système. L'utilisateur doit ensuite cocher l'application
	/// dans Réglages Système ; le résultat n'est pas immédiat.
	public static func requestPermissions() {
		// Valeur de `kAXTrustedCheckOptionPrompt`, qu'on ne peut pas lire sans avertissement en Swift 6.
		let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(options)
		_ = CGRequestListenEventAccess()
	}

	// MARK: - Cycle de vie

	public func start() throws(KeyboardCaptureError) {
		guard tap == nil else { return }
		guard Self.hasPermissions else { throw .missingPermissions }
		let mask = (1 << CGEventType.keyDown.rawValue)
			| (1 << CGEventType.keyUp.rawValue)
			| (1 << CGEventType.flagsChanged.rawValue)
		guard let tap = CGEvent.tapCreate(
			tap: .cghidEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(mask),
			callback: keyboardTapCallback,
			userInfo: Unmanaged.passUnretained(self).toOpaque(),
		) else { throw .tapCreationFailed }
		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)
		self.tap = tap
		runLoopSource = source
	}

	public func stop() {
		setRemote(false)
		guard let tap else { return }
		CGEvent.tapEnable(tap: tap, enable: false)
		if let runLoopSource {
			CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
		}
		CFMachPortInvalidate(tap)
		self.tap = nil
		runLoopSource = nil
	}

	/// Passe en contrôle du PC ou revient au Mac. Au retour, toutes les touches encore
	/// enfoncées côté PC y sont relâchées.
	public func setRemote(_ remote: Bool) {
		guard remote != isRemote else { return }
		if remote {
			layout.reload()
			sentDown.removeAll()
		} else {
			releaseAll()
		}
		isRemote = remote
	}

	private func releaseAll() {
		guard !sentDown.isEmpty else { return }
		// Comme NVDA : une touche neutre d'abord, pour que relâcher un modificateur seul
		// ne déclenche rien sur le PC (Alt qui ouvrirait un menu, par exemple).
		onKey?(.none, true)
		onKey?(.none, false)
		for key in sentDown.reversed() {
			onKey?(key, false)
		}
		sentDown.removeAll()
	}

	// MARK: - Événements

	/// Ce qu'on retient d'un événement clavier : des valeurs simples, lues sur place.
	struct KeyEvent: Sendable {
		var type: CGEventType
		var keyCode: UInt16
		var flags: CGEventFlags
		var isRepeat: Bool

		init(type: CGEventType, keyCode: UInt16, flags: CGEventFlags = [], isRepeat: Bool = false) {
			self.type = type
			self.keyCode = keyCode
			self.flags = flags
			self.isRepeat = isRepeat
		}

		init(type: CGEventType, event: CGEvent) {
			self.type = type
			keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
			flags = event.flags
			isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
		}
	}

	/// - Returns: `true` pour avaler l'événement.
	func handle(_ event: KeyEvent) -> Bool {
		let keyCode = event.keyCode
		switch event.type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap {
				CGEvent.tapEnable(tap: tap, enable: true)
			}
			return false
		case .keyDown:
			if isToggleEnabled, toggleShortcut.matches(keyCode: keyCode, flags: event.flags) {
				swallowedKeyUps.insert(keyCode)
				if !event.isRepeat {
					onToggle?()
				}
				return true
			}
			guard isRemote else { return false }
			press(keyCode)
			return true
		case .keyUp:
			if swallowedKeyUps.remove(keyCode) != nil {
				return true
			}
			guard isRemote else { return false }
			return release(keyCode)
		case .flagsChanged:
			guard isRemote else { return false }
			if keyCode == MacKeyCode.capsLock {
				return true
			}
			guard let pressed = Self.isModifierPressed(keyCode, flags: event.flags) else { return true }
			if pressed {
				press(keyCode)
				return true
			}
			return release(keyCode)
		default:
			return false
		}
	}

	private func press(_ keyCode: UInt16) {
		guard let key = translator.translate(keyCode: keyCode, characters: layout.characters(for: keyCode)) else { return }
		if !sentDown.contains(key) {
			sentDown.append(key)
		}
		// Une touche maintenue répète son appui, comme sous Windows.
		onKey?(key, true)
	}

	private func release(_ keyCode: UInt16) -> Bool {
		guard let key = translator.translate(keyCode: keyCode, characters: layout.characters(for: keyCode)),
			let index = sentDown.firstIndex(of: key)
		else { return false }
		sentDown.remove(at: index)
		onKey?(key, false)
		return true
	}

	/// État d'un modificateur après un `flagsChanged`, par les masques qui distinguent
	/// gauche et droite (`NX_DEVICE*KEYMASK`). `nil` pour une touche qui n'en est pas un.
	nonisolated static func isModifierPressed(_ keyCode: UInt16, flags: CGEventFlags) -> Bool? {
		let deviceMasks: [UInt16: UInt64] = [
			MacKeyCode.control: 0x0001,
			MacKeyCode.shift: 0x0002,
			MacKeyCode.rightShift: 0x0004,
			MacKeyCode.command: 0x0008,
			MacKeyCode.rightCommand: 0x0010,
			MacKeyCode.option: 0x0020,
			MacKeyCode.rightOption: 0x0040,
			MacKeyCode.rightControl: 0x2000,
		]
		if keyCode == MacKeyCode.function {
			// Fiable ici, puisque c'est l'événement de fn lui-même.
			return flags.contains(.maskSecondaryFn)
		}
		guard let mask = deviceMasks[keyCode] else { return nil }
		return flags.rawValue & mask != 0
	}
}

public enum KeyboardCaptureError: Error, LocalizedError {
	case missingPermissions
	case tapCreationFailed

	public var errorDescription: String? {
		switch self {
		case .missingPermissions:
			"L'application n'a pas encore les autorisations Accessibilité et Surveillance de l'entrée."
		case .tapCreationFailed:
			"Impossible d'intercepter le clavier."
		}
	}
}

/// Le tap est posé sur la boucle principale : ce rappel s'exécute donc sur le fil principal.
private func keyboardTapCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
	guard let userInfo else { return Unmanaged.passUnretained(event) }
	let capture = Unmanaged<KeyboardCapture>.fromOpaque(userInfo).takeUnretainedValue()
	let keyEvent = KeyboardCapture.KeyEvent(type: type, event: event)
	let swallow = MainActor.assumeIsolated { capture.handle(keyEvent) }
	return swallow ? nil : Unmanaged.passUnretained(event)
}

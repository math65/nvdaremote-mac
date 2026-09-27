import Foundation

/// Touche Windows telle que le protocole l'envoie : code virtuel et drapeau « étendue ».
public struct WindowsKey: Hashable, Sendable {
	public var vk: Int
	public var extended: Bool

	public init(_ vk: Int, extended: Bool = false) {
		self.vk = vk
		self.extended = extended
	}

	/// Touche NVDA par défaut sur le PC : Insert, étendue.
	public static let insert = WindowsKey(0x2D, extended: true)
	/// Touche neutre que NVDA envoie pour casser une combinaison avant de relâcher les modificateurs.
	public static let none = WindowsKey(0xFF)
}

/// Touche du Mac qui joue le rôle de la touche NVDA.
public enum NVDAKeyChoice: String, CaseIterable, Sendable {
	/// Verrouillage majuscules, remappée en F18 par `hidutil` pendant le contrôle du PC.
	case capsLock
	case rightOption
	case fn

	public var label: String {
		switch self {
		case .capsLock: "Verrouillage majuscules"
		case .rightOption: "Option droite"
		case .fn: "fn (Globe)"
		}
	}
}

/// Disposition du clavier configurée sur le PC. Elle décide quel code virtuel produit quel caractère.
public enum PCLayout: String, CaseIterable, Sendable {
	case french
	case us

	public var label: String {
		switch self {
		case .french: "Français (AZERTY)"
		case .us: "Américain (QWERTY)"
		}
	}
}

/// Codes de touches macOS utilisés ici (constantes `kVK_*` de Carbon).
public enum MacKeyCode {
	public static let returnKey: UInt16 = 36
	public static let tab: UInt16 = 48
	public static let space: UInt16 = 49
	public static let delete: UInt16 = 51
	public static let escape: UInt16 = 53
	public static let rightCommand: UInt16 = 54
	public static let command: UInt16 = 55
	public static let shift: UInt16 = 56
	public static let capsLock: UInt16 = 57
	public static let option: UInt16 = 58
	public static let control: UInt16 = 59
	public static let rightShift: UInt16 = 60
	public static let rightOption: UInt16 = 61
	public static let rightControl: UInt16 = 62
	public static let function: UInt16 = 63
	public static let f18: UInt16 = 79
	/// Touche Globe des claviers récents, absente des constantes Carbon.
	public static let globe: UInt16 = 179
}

/// Traduit une touche du Mac en touche Windows pour le PC distant.
///
/// Voir docs/mesures-clavier.md : les codes de touche macOS désignent une position
/// physique, alors que les codes virtuels Windows désignent ce que la touche produit.
/// La correspondance se fait donc d'abord par caractère produit, sans modificateurs.
public struct KeyTranslator: Sendable {
	/// Caractères produits par une touche du Mac, sans modificateur et avec Majuscule seule.
	public struct Characters: Equatable, Sendable {
		public var plain: String
		public var shifted: String

		public init(plain: String, shifted: String) {
			self.plain = plain
			self.shifted = shifted
		}
	}

	public var nvdaKey: NVDAKeyChoice
	public var pcLayout: PCLayout

	public init(nvdaKey: NVDAKeyChoice = .capsLock, pcLayout: PCLayout = .french) {
		self.nvdaKey = nvdaKey
		self.pcLayout = pcLayout
	}

	/// - Parameter characters: ce que produit la touche sur la disposition active du Mac ;
	///   `nil` pour une touche muette.
	/// - Returns: la touche à envoyer, ou `nil` si elle n'a pas d'équivalent sur le PC.
	public func translate(keyCode: UInt16, characters: Characters?) -> WindowsKey? {
		if let special = specialKey(keyCode) {
			return special
		}
		// Ces touches n'ont d'usage qu'en touche NVDA : sinon, rien à envoyer.
		if [MacKeyCode.capsLock, MacKeyCode.function, MacKeyCode.globe].contains(keyCode) {
			return nil
		}
		if let characters {
			let plain = characters.plain.lowercased()
			if let letter = plain.unicodeScalars.first, plain.unicodeScalars.count == 1,
				("a"..."z").contains(letter)
			{
				return WindowsKey(0x41 + Int(letter.value - 0x61))
			}
			// Sur azerty, la rangée du haut ne donne ses chiffres qu'avec Majuscule.
			for candidate in [characters.plain, characters.shifted] {
				if candidate.count == 1, let digit = candidate.first?.wholeNumberValue, candidate.first!.isASCII {
					return WindowsKey(0x30 + digit)
				}
			}
			if let entry = punctuation.first(where: { $0.plain == characters.plain }) {
				return WindowsKey(entry.vk)
			}
		}
		if let entry = punctuation.first(where: { $0.position == keyCode }) {
			return WindowsKey(entry.vk)
		}
		return nil
	}

	/// Touches qui ne dépendent pas de la disposition : navigation, fonctions, modificateurs, pavé numérique.
	private func specialKey(_ keyCode: UInt16) -> WindowsKey? {
		switch (nvdaKey, keyCode) {
		case (.capsLock, MacKeyCode.f18), (.rightOption, MacKeyCode.rightOption), (.fn, MacKeyCode.function):
			return .insert
		default:
			return Self.fixedKeys[keyCode]
		}
	}

	private static let fixedKeys: [UInt16: WindowsKey] = [
		MacKeyCode.returnKey: WindowsKey(0x0D),
		MacKeyCode.tab: WindowsKey(0x09),
		MacKeyCode.space: WindowsKey(0x20),
		MacKeyCode.delete: WindowsKey(0x08),
		MacKeyCode.escape: WindowsKey(0x1B),
		117: WindowsKey(0x2E, extended: true), // Suppression avant
		114: WindowsKey(0x2D, extended: true), // Aide, à la place d'Insert sur les claviers étendus
		115: WindowsKey(0x24, extended: true), // Début
		119: WindowsKey(0x23, extended: true), // Fin
		116: WindowsKey(0x21, extended: true), // Page précédente
		121: WindowsKey(0x22, extended: true), // Page suivante
		123: WindowsKey(0x25, extended: true), // Gauche
		124: WindowsKey(0x27, extended: true), // Droite
		125: WindowsKey(0x28, extended: true), // Bas
		126: WindowsKey(0x26, extended: true), // Haut

		// Modificateurs : Contrôle reste Contrôle, Option devient Alt, Commande devient Windows.
		MacKeyCode.shift: WindowsKey(0xA0),
		MacKeyCode.rightShift: WindowsKey(0xA1),
		MacKeyCode.control: WindowsKey(0xA2),
		MacKeyCode.rightControl: WindowsKey(0xA3, extended: true),
		MacKeyCode.option: WindowsKey(0xA4),
		MacKeyCode.rightOption: WindowsKey(0xA5, extended: true),
		MacKeyCode.command: WindowsKey(0x5B, extended: true),
		MacKeyCode.rightCommand: WindowsKey(0x5C, extended: true),

		// Touches de fonction F1 à F20.
		122: WindowsKey(0x70), 120: WindowsKey(0x71), 99: WindowsKey(0x72), 118: WindowsKey(0x73),
		96: WindowsKey(0x74), 97: WindowsKey(0x75), 98: WindowsKey(0x76), 100: WindowsKey(0x77),
		101: WindowsKey(0x78), 109: WindowsKey(0x79), 103: WindowsKey(0x7A), 111: WindowsKey(0x7B),
		105: WindowsKey(0x7C), 107: WindowsKey(0x7D), 113: WindowsKey(0x7E), 106: WindowsKey(0x7F),
		64: WindowsKey(0x80), MacKeyCode.f18: WindowsKey(0x81), 80: WindowsKey(0x82), 90: WindowsKey(0x83),

		// Pavé numérique, Verr. num. désactivé : ce que la disposition « ordinateur de bureau »
		// de NVDA attend (numpad8 = Haut non étendu, etc.).
		82: WindowsKey(0x2D), 83: WindowsKey(0x23), 84: WindowsKey(0x28), 85: WindowsKey(0x22),
		86: WindowsKey(0x25), 87: WindowsKey(0x0C), 88: WindowsKey(0x27), 89: WindowsKey(0x24),
		91: WindowsKey(0x26), 92: WindowsKey(0x21),
		65: WindowsKey(0x2E), // Point décimal = Suppr du pavé
		67: WindowsKey(0x6A), // *
		69: WindowsKey(0x6B), // +
		78: WindowsKey(0x6D), // -
		75: WindowsKey(0x6F, extended: true), // /
		76: WindowsKey(0x0D, extended: true), // Entrée du pavé
	]

	// MARK: - Ponctuation, par disposition du PC

	/// Touche de ponctuation du PC : code virtuel, caractère produit sans modificateur,
	/// et code de la touche du Mac située au même endroit, pour le repli positionnel.
	private struct PunctuationKey {
		var vk: Int
		var plain: String
		var position: UInt16
	}

	private var punctuation: [PunctuationKey] {
		switch pcLayout {
		case .french: Self.frenchPunctuation
		case .us: Self.usPunctuation
		}
	}

	private static let frenchPunctuation = [
		PunctuationKey(vk: 0xDE, plain: "²", position: 50),
		PunctuationKey(vk: 0xDB, plain: ")", position: 27),
		PunctuationKey(vk: 0xBB, plain: "=", position: 24),
		PunctuationKey(vk: 0xDD, plain: "^", position: 33),
		PunctuationKey(vk: 0xBA, plain: "$", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ù", position: 39),
		PunctuationKey(vk: 0xDC, plain: "*", position: 42),
		PunctuationKey(vk: 0xE2, plain: "<", position: 10),
		PunctuationKey(vk: 0xBC, plain: ",", position: 46),
		PunctuationKey(vk: 0xBE, plain: ";", position: 43),
		PunctuationKey(vk: 0xBF, plain: ":", position: 47),
		PunctuationKey(vk: 0xDF, plain: "!", position: 44),
		// Caractères de la rangée du haut sans chiffre associé au même endroit sur le Mac.
		PunctuationKey(vk: 0x36, plain: "-", position: 22),
		PunctuationKey(vk: 0x38, plain: "_", position: 28),
	]

	private static let usPunctuation = [
		PunctuationKey(vk: 0xC0, plain: "`", position: 50),
		PunctuationKey(vk: 0xBD, plain: "-", position: 27),
		PunctuationKey(vk: 0xBB, plain: "=", position: 24),
		PunctuationKey(vk: 0xDB, plain: "[", position: 33),
		PunctuationKey(vk: 0xDD, plain: "]", position: 30),
		PunctuationKey(vk: 0xDC, plain: "\\", position: 42),
		PunctuationKey(vk: 0xBA, plain: ";", position: 41),
		PunctuationKey(vk: 0xDE, plain: "'", position: 39),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBF, plain: "/", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 10),
	]
}

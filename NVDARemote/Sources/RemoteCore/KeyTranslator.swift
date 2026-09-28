import Foundation

/// A Windows key as the protocol sends it: virtual-key code and "extended" flag.
public struct WindowsKey: Hashable, Sendable {
	public var vk: Int
	public var extended: Bool

	public init(_ vk: Int, extended: Bool = false) {
		self.vk = vk
		self.extended = extended
	}

	/// Default NVDA key on the PC: Insert, extended.
	public static let insert = WindowsKey(0x2D, extended: true)
	/// Neutral key NVDA sends to break a combination before releasing the modifiers.
	public static let none = WindowsKey(0xFF)
}

/// The Mac key that acts as the NVDA key.
public enum NVDAKeyChoice: String, CaseIterable, Sendable {
	/// Caps Lock, remapped to F18 by `hidutil` while controlling the PC.
	case capsLock
	case rightOption
	case fn

	public var label: String {
		switch self {
		case .capsLock: localized("Caps Lock")
		case .rightOption: localized("Right Option")
		case .fn: localized("fn (Globe)")
		}
	}
}

/// Keyboard layout configured on the PC. It determines which virtual-key code produces which character.
public enum PCLayout: String, CaseIterable, Sendable {
	case french
	case belgian
	case swissFrench
	case canadianFrench
	case us
	case uk
	case german
	case spanish
	case italian

	public var label: String {
		switch self {
		case .french: localized("French (AZERTY)")
		case .belgian: localized("Belgian French (AZERTY)")
		case .swissFrench: localized("Swiss French (QWERTZ)")
		case .canadianFrench: localized("Canadian French")
		case .us: localized("US (QWERTY)")
		case .uk: localized("United Kingdom (QWERTY)")
		case .german: localized("German (QWERTZ)")
		case .spanish: localized("Spanish (QWERTY)")
		case .italian: localized("Italian (QWERTY)")
		}
	}
}

/// How Mac keys become PC keys when typing.
public enum KeyMapping: String, CaseIterable, Sendable {
	/// Each key types on the PC what it types on the Mac, whatever the two layouts.
	case characters
	/// Each key is sent as the PC key at the same place on the keyboard, and the PC's
	/// layout decides what it types, as if the Mac's keyboard were plugged into the PC.
	case positions

	public var label: String {
		switch self {
		case .characters: localized("Same characters as on the Mac")
		case .positions: localized("Same keys as on the PC keyboard")
		}
	}
}

extension PCLayout {
	/// The PC layout that most likely matches the Mac's own keyboard layout: someone
	/// who types on a French AZERTY Mac usually has a French AZERTY PC. Used as the
	/// default until the user picks one in Settings.
	/// - Parameter macInputSourceID: the Mac layout's input source identifier, such as
	///   "com.apple.keylayout.French".
	public init(matchingMacLayout macInputSourceID: String?) {
		let id = macInputSourceID ?? ""
		// Most specific first: "SwissFrench" and "CanadianFrench-PC" also contain "French".
		let matches: [(names: [String], layout: PCLayout)] = [
			(["SwissFrench"], .swissFrench),
			(["Canadian"], .canadianFrench),
			(["Belgian"], .belgian),
			(["French", "AZERTY"], .french),
			(["British", "Irish"], .uk),
			(["German", "Austrian"], .german),
			(["Spanish"], .spanish),
			(["Italian"], .italian),
		]
		// Swiss German is left out: its PC layout differs from both Swiss French and German.
		let match = matches.first { $0.names.contains { id.contains($0) } && !id.contains("SwissGerman") }
		self = match?.layout ?? .us
	}
}

/// A character as the PC types it: the key, and the modifiers the PC's layout needs
/// for it. Shift may differ from what the user holds on the Mac, for example "1" is
/// Shift-& on a French Mac but a plain key on a US PC.
public struct TypedKey: Equatable, Sendable {
	public var key: WindowsKey
	public var shift: Bool
	public var altGr: Bool

	public init(_ vk: Int, shift: Bool = false, altGr: Bool = false) {
		key = WindowsKey(vk)
		self.shift = shift
		self.altGr = altGr
	}
}

/// macOS key codes used here (Carbon `kVK_*` constants).
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
	/// Globe key on recent keyboards, missing from the Carbon constants.
	public static let globe: UInt16 = 179
}

/// Translates a Mac key into a Windows key for the remote PC.
///
/// See docs/keyboard-measurements.md: macOS key codes identify a physical position,
/// whereas Windows virtual-key codes identify what the key produces. Matching is
/// therefore done first by the character produced, without modifiers.
public struct KeyTranslator: Sendable {
	/// Characters produced by a Mac key, with no modifier and with Shift alone.
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
	public var mapping: KeyMapping

	public init(nvdaKey: NVDAKeyChoice = .capsLock, pcLayout: PCLayout = .french, mapping: KeyMapping = .characters) {
		self.nvdaKey = nvdaKey
		self.pcLayout = pcLayout
		self.mapping = mapping
	}

	/// The PC key at the same place as a Mac key, for `KeyMapping.positions`: the PC's
	/// layout then decides the character, and Shift, Option and the others pass as held.
	/// - Parameter isANSIKeyboard: on ANSI keyboards (US style) the key left of 1 is
	///   code 50, which is the key left of Z on ISO keyboards.
	public func positionalKey(keyCode: UInt16, isANSIKeyboard: Bool) -> WindowsKey? {
		if let special = specialKey(keyCode) {
			return special
		}
		let position = isANSIKeyboard && keyCode == 50 ? 10 : keyCode
		guard let vk = Self.positionChanges[pcLayout]?[position] ?? Self.usPositions[position] else { return nil }
		return WindowsKey(vk)
	}

	/// - Parameter characters: what the key produces with the Mac's active layout;
	///   `nil` for a key that produces no character.
	/// - Returns: the key to send, or `nil` if it has no equivalent on the PC.
	/// - Parameter shift: whether Shift is held. On AZERTY the top row types digits with
	///   Shift and punctuation without, so the key sent depends on it: "!" without Shift
	///   is the PC's "!" key, "8" with Shift is the PC's 8 key.
	public func translate(keyCode: UInt16, characters: Characters?, shift: Bool = false) -> WindowsKey? {
		if let special = specialKey(keyCode) {
			return special
		}
		// These keys are only useful as the NVDA key: otherwise, there is nothing to send.
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
			if shift, let digit = Self.digit(characters.shifted) {
				return WindowsKey(0x30 + digit)
			}
			if let entry = punctuation.first(where: { $0.plain == characters.plain }) {
				return WindowsKey(entry.vk)
			}
			// On AZERTY, the top row only produces digits with Shift.
			if let digit = Self.digit(characters.plain) ?? Self.digit(characters.shifted) {
				return WindowsKey(0x30 + digit)
			}
		}
		if let entry = punctuation.first(where: { $0.position == keyCode }) {
			return WindowsKey(entry.vk)
		}
		return nil
	}

	/// Keys sent the same whatever the layouts: navigation, function and modifier keys,
	/// the keypad, and letters (their virtual-key code types the same letter on every
	/// Latin layout, and Shift keeps its meaning).
	public func isLayoutIndependent(keyCode: UInt16, characters: Characters) -> Bool {
		if specialKey(keyCode) != nil {
			return true
		}
		let plain = characters.plain.lowercased()
		guard let letter = plain.unicodeScalars.first, plain.unicodeScalars.count == 1 else { return false }
		return ("a"..."z").contains(letter)
	}

	/// How the PC types a character that is neither a letter nor a layout-independent
	/// key, or `nil` if its layout cannot type it. Letters are left to `translate`:
	/// their virtual-key code types the same letter on every Latin layout.
	public func typedKey(for character: String) -> TypedKey? {
		switch pcLayout {
		case .french: Self.frenchTyped[character]
		case .belgian: Self.belgianTyped[character]
		case .swissFrench: Self.swissFrenchTyped[character]
		case .canadianFrench: Self.canadianFrenchTyped[character]
		case .us: Self.usTyped[character]
		case .uk: Self.ukTyped[character]
		case .german: Self.germanTyped[character]
		case .spanish: Self.spanishTyped[character]
		case .italian: Self.italianTyped[character]
		}
	}

	private static func digit(_ text: String) -> Int? {
		guard text.count == 1, let character = text.first, character.isASCII else { return nil }
		return character.wholeNumberValue
	}

	/// Layout-independent keys: navigation, function keys, modifiers, numeric keypad.
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
		117: WindowsKey(0x2E, extended: true), // Forward Delete
		114: WindowsKey(0x2D, extended: true), // Help, in place of Insert on extended keyboards
		115: WindowsKey(0x24, extended: true), // Home
		119: WindowsKey(0x23, extended: true), // End
		116: WindowsKey(0x21, extended: true), // Page Up
		121: WindowsKey(0x22, extended: true), // Page Down
		123: WindowsKey(0x25, extended: true), // Left
		124: WindowsKey(0x27, extended: true), // Right
		125: WindowsKey(0x28, extended: true), // Down
		126: WindowsKey(0x26, extended: true), // Up

		// Modifiers: Control stays Control, Option becomes Alt, Command becomes the Windows key.
		MacKeyCode.shift: WindowsKey(0xA0),
		MacKeyCode.rightShift: WindowsKey(0xA1),
		MacKeyCode.control: WindowsKey(0xA2),
		MacKeyCode.rightControl: WindowsKey(0xA3, extended: true),
		MacKeyCode.option: WindowsKey(0xA4),
		MacKeyCode.rightOption: WindowsKey(0xA5, extended: true),
		MacKeyCode.command: WindowsKey(0x5B, extended: true),
		MacKeyCode.rightCommand: WindowsKey(0x5C, extended: true),

		// Function keys F1 to F20.
		122: WindowsKey(0x70), 120: WindowsKey(0x71), 99: WindowsKey(0x72), 118: WindowsKey(0x73),
		96: WindowsKey(0x74), 97: WindowsKey(0x75), 98: WindowsKey(0x76), 100: WindowsKey(0x77),
		101: WindowsKey(0x78), 109: WindowsKey(0x79), 103: WindowsKey(0x7A), 111: WindowsKey(0x7B),
		105: WindowsKey(0x7C), 107: WindowsKey(0x7D), 113: WindowsKey(0x7E), 106: WindowsKey(0x7F),
		64: WindowsKey(0x80), MacKeyCode.f18: WindowsKey(0x81), 80: WindowsKey(0x82), 90: WindowsKey(0x83),

		// Numeric keypad with Num Lock off: what NVDA's "desktop" keyboard layout
		// expects (numpad8 = non-extended Up, etc.).
		82: WindowsKey(0x2D), 83: WindowsKey(0x23), 84: WindowsKey(0x28), 85: WindowsKey(0x22),
		86: WindowsKey(0x25), 87: WindowsKey(0x0C), 88: WindowsKey(0x27), 89: WindowsKey(0x24),
		91: WindowsKey(0x26), 92: WindowsKey(0x21),
		65: WindowsKey(0x2E), // Decimal point = keypad Delete
		67: WindowsKey(0x6A), // *
		69: WindowsKey(0x6B), // +
		78: WindowsKey(0x6D), // -
		75: WindowsKey(0x6F, extended: true), // /
		76: WindowsKey(0x0D, extended: true), // Keypad Enter
	]

	// MARK: - Punctuation, by PC layout

	/// A PC punctuation key: virtual-key code, character produced without modifiers,
	/// and the code of the Mac key at the same position, for the positional fallback.
	private struct PunctuationKey {
		var vk: Int
		var plain: String
		var position: UInt16
	}

	private var punctuation: [PunctuationKey] {
		switch pcLayout {
		case .french: Self.frenchPunctuation
		case .belgian: Self.belgianPunctuation
		case .swissFrench: Self.swissFrenchPunctuation
		case .canadianFrench: Self.canadianFrenchPunctuation
		case .us: Self.usPunctuation
		case .uk: Self.ukPunctuation
		case .german: Self.germanPunctuation
		case .spanish: Self.spanishPunctuation
		case .italian: Self.italianPunctuation
		}
	}

	private static let frenchPunctuation = [
		PunctuationKey(vk: 0xDE, plain: "²", position: 10),
		PunctuationKey(vk: 0xDB, plain: ")", position: 27),
		PunctuationKey(vk: 0xBB, plain: "=", position: 24),
		PunctuationKey(vk: 0xDD, plain: "^", position: 33),
		PunctuationKey(vk: 0xBA, plain: "$", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ù", position: 39),
		PunctuationKey(vk: 0xDC, plain: "*", position: 42),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
		PunctuationKey(vk: 0xBC, plain: ",", position: 46),
		PunctuationKey(vk: 0xBE, plain: ";", position: 43),
		PunctuationKey(vk: 0xBF, plain: ":", position: 47),
		PunctuationKey(vk: 0xDF, plain: "!", position: 44),
		// Top-row characters with no digit at the same position on the Mac.
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
		// The extra key of 102-key keyboards types a backslash in the US layout; on Apple
		// ISO keyboards the key at its place is code 10, left of 1.
		PunctuationKey(vk: 0xE2, plain: "\\", position: 10),
	]

	// Generated from Microsoft's layout tables. On these ISO keyboards the key left of 1
	// is code 10 on the Mac and the key left of Z is code 50, as measured on AZERTY.

	private static let ukPunctuation = [
		PunctuationKey(vk: 0xBD, plain: "-", position: 27),
		PunctuationKey(vk: 0xBB, plain: "=", position: 24),
		PunctuationKey(vk: 0xDB, plain: "[", position: 33),
		PunctuationKey(vk: 0xDD, plain: "]", position: 30),
		PunctuationKey(vk: 0xBA, plain: ";", position: 41),
		PunctuationKey(vk: 0xC0, plain: "'", position: 39),
		PunctuationKey(vk: 0xDF, plain: "`", position: 10),
		PunctuationKey(vk: 0xDE, plain: "#", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBF, plain: "/", position: 44),
		PunctuationKey(vk: 0xDC, plain: "\\", position: 50),
	]

	private static let canadianFrenchPunctuation = [
		PunctuationKey(vk: 0xBD, plain: "-", position: 27),
		PunctuationKey(vk: 0xBB, plain: "=", position: 24),
		PunctuationKey(vk: 0xDB, plain: "^", position: 33),
		PunctuationKey(vk: 0xDD, plain: "¸", position: 30),
		PunctuationKey(vk: 0xBA, plain: ";", position: 41),
		PunctuationKey(vk: 0xC0, plain: "`", position: 39),
		PunctuationKey(vk: 0xDE, plain: "#", position: 10),
		PunctuationKey(vk: 0xDC, plain: "<", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBF, plain: "é", position: 44),
		PunctuationKey(vk: 0xE2, plain: "«", position: 50),
	]

	private static let belgianPunctuation = [
		PunctuationKey(vk: 0xDB, plain: ")", position: 27),
		PunctuationKey(vk: 0xBD, plain: "-", position: 24),
		PunctuationKey(vk: 0xDD, plain: "^", position: 33),
		PunctuationKey(vk: 0xBA, plain: "$", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ù", position: 39),
		PunctuationKey(vk: 0xDE, plain: "²", position: 10),
		PunctuationKey(vk: 0xDC, plain: "µ", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 46),
		PunctuationKey(vk: 0xBE, plain: ";", position: 43),
		PunctuationKey(vk: 0xBF, plain: ":", position: 47),
		PunctuationKey(vk: 0xBB, plain: "=", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
	]

	private static let swissFrenchPunctuation = [
		PunctuationKey(vk: 0xDB, plain: "'", position: 27),
		PunctuationKey(vk: 0xDD, plain: "^", position: 24),
		PunctuationKey(vk: 0xBA, plain: "è", position: 33),
		PunctuationKey(vk: 0xC0, plain: "¨", position: 30),
		PunctuationKey(vk: 0xDE, plain: "é", position: 41),
		PunctuationKey(vk: 0xDC, plain: "à", position: 39),
		PunctuationKey(vk: 0xBF, plain: "§", position: 10),
		PunctuationKey(vk: 0xDF, plain: "$", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBD, plain: "-", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
	]

	private static let germanPunctuation = [
		PunctuationKey(vk: 0xDB, plain: "ß", position: 27),
		PunctuationKey(vk: 0xDD, plain: "´", position: 24),
		PunctuationKey(vk: 0xBA, plain: "ü", position: 33),
		PunctuationKey(vk: 0xBB, plain: "+", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ö", position: 41),
		PunctuationKey(vk: 0xDE, plain: "ä", position: 39),
		PunctuationKey(vk: 0xDC, plain: "^", position: 10),
		PunctuationKey(vk: 0xBF, plain: "#", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBD, plain: "-", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
	]

	private static let spanishPunctuation = [
		PunctuationKey(vk: 0xDB, plain: "'", position: 27),
		PunctuationKey(vk: 0xDD, plain: "¡", position: 24),
		PunctuationKey(vk: 0xBA, plain: "`", position: 33),
		PunctuationKey(vk: 0xBB, plain: "+", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ñ", position: 41),
		PunctuationKey(vk: 0xDE, plain: "´", position: 39),
		PunctuationKey(vk: 0xDC, plain: "º", position: 10),
		PunctuationKey(vk: 0xBF, plain: "ç", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBD, plain: "-", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
	]

	private static let italianPunctuation = [
		PunctuationKey(vk: 0xDB, plain: "'", position: 27),
		PunctuationKey(vk: 0xDD, plain: "ì", position: 24),
		PunctuationKey(vk: 0xBA, plain: "è", position: 33),
		PunctuationKey(vk: 0xBB, plain: "+", position: 30),
		PunctuationKey(vk: 0xC0, plain: "ò", position: 41),
		PunctuationKey(vk: 0xDE, plain: "à", position: 39),
		PunctuationKey(vk: 0xDC, plain: "\\", position: 10),
		PunctuationKey(vk: 0xBF, plain: "ù", position: 42),
		PunctuationKey(vk: 0xBC, plain: ",", position: 43),
		PunctuationKey(vk: 0xBE, plain: ".", position: 47),
		PunctuationKey(vk: 0xBD, plain: "-", position: 44),
		PunctuationKey(vk: 0xE2, plain: "<", position: 50),
	]

	// MARK: - Positions, by PC layout

	/// Windows key at each position of a US PC keyboard, by Mac key code (ISO: 10 is
	/// left of 1, 50 left of Z).
	private static let usPositions: [UInt16: Int] = [
		18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35, 22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39, 29: 0x30, 27: 0xBD, 24: 0xBB,
		12: 0x51, 13: 0x57, 14: 0x45, 15: 0x52, 17: 0x54, 16: 0x59, 32: 0x55, 34: 0x49, 31: 0x4F, 35: 0x50, 33: 0xDB, 30: 0xDD,
		0: 0x41, 1: 0x53, 2: 0x44, 3: 0x46, 5: 0x47, 4: 0x48, 38: 0x4A, 40: 0x4B, 37: 0x4C, 41: 0xBA, 39: 0xDE, 42: 0xDC,
		6: 0x5A, 7: 0x58, 8: 0x43, 9: 0x56, 11: 0x42, 45: 0x4E, 46: 0x4D, 43: 0xBC, 47: 0xBE, 44: 0xBF,
		10: 0xC0, 50: 0xE2,
	]

	/// What differs from `usPositions` on each other layout.
	private static let positionChanges: [PCLayout: [UInt16: Int]] = [
		.french: [0: 0x51, 6: 0x57, 10: 0xDE, 12: 0x41, 13: 0x5A, 27: 0xDB, 30: 0xBA, 33: 0xDD, 39: 0xC0, 41: 0x4D, 43: 0xBE, 44: 0xDF, 46: 0xBC, 47: 0xBF],
		.belgian: [0: 0x51, 6: 0x57, 10: 0xDE, 12: 0x41, 13: 0x5A, 24: 0xBD, 27: 0xDB, 30: 0xBA, 33: 0xDD, 39: 0xC0, 41: 0x4D, 43: 0xBE, 44: 0xBB, 46: 0xBC, 47: 0xBF],
		.swissFrench: [6: 0x59, 10: 0xBF, 16: 0x5A, 24: 0xDD, 27: 0xDB, 30: 0xC0, 33: 0xBA, 39: 0xDC, 41: 0xDE, 42: 0xDF, 44: 0xBD],
		.canadianFrench: [10: 0xDE, 39: 0xC0],
		.uk: [10: 0xDF, 39: 0xC0, 42: 0xDE, 50: 0xDC],
		.german: [6: 0x59, 10: 0xDC, 16: 0x5A, 24: 0xDD, 27: 0xDB, 30: 0xBB, 33: 0xBA, 41: 0xC0, 42: 0xBF, 44: 0xBD],
		.spanish: [10: 0xDC, 24: 0xDD, 27: 0xDB, 30: 0xBB, 33: 0xBA, 41: 0xC0, 42: 0xBF, 44: 0xBD],
		.italian: [10: 0xDC, 24: 0xDD, 27: 0xDB, 30: 0xBB, 33: 0xBA, 41: 0xC0, 42: 0xBF, 44: 0xBD],
	]

	// MARK: - Characters, by PC layout

	/// Builds a character table from rows of (virtual-key code, plain, Shift, AltGr),
	/// plus the few characters typed with Shift and AltGr together. A character on
	/// several keys goes to the one with the fewest modifiers, then to the first listed.
	/// That also picks dead keys where it matters: "^" is a plain dead key on a French
	/// PC but AltGr-9 types it alone, and "^" then "e" must give "ê", as on the Mac.
	private static func table(
		_ rows: [(vk: Int, plain: String?, shifted: String?, altGr: String?)],
		shiftedAltGr: [(vk: Int, character: String)] = []
	) -> [String: TypedKey] {
		var table: [String: TypedKey] = [:]
		func add(_ character: String?, _ key: TypedKey) {
			if let character, table[character] == nil { table[character] = key }
		}
		for row in rows { add(row.plain, TypedKey(row.vk)) }
		for row in rows { add(row.shifted, TypedKey(row.vk, shift: true)) }
		for row in rows { add(row.altGr, TypedKey(row.vk, altGr: true)) }
		for row in shiftedAltGr { add(row.character, TypedKey(row.vk, shift: true, altGr: true)) }
		return table
	}

	/// Windows "French" layout (kbdfr).
	private static let frenchTyped = table([
		(0xDD, "^", "¨", nil), // dead keys
		(0x31, "&", "1", nil),
		(0x32, "é", "2", "~"),
		(0x33, "\"", "3", "#"),
		(0x34, "'", "4", "{"),
		(0x35, "(", "5", "["),
		(0x36, "-", "6", "|"),
		(0x37, "è", "7", "`"),
		(0x38, "_", "8", "\\"),
		(0x39, "ç", "9", "^"),
		(0x30, "à", "0", "@"),
		(0xDB, ")", "°", "]"),
		(0xBB, "=", "+", "}"),
		(0xDE, "²", nil, nil),
		(0xBA, "$", "£", "¤"),
		(0xC0, "ù", "%", nil),
		(0xDC, "*", "µ", nil),
		(0xBC, ",", "?", nil),
		(0xBE, ";", ".", nil),
		(0xBF, ":", "/", nil),
		(0xDF, "!", "§", nil),
		(0xE2, "<", ">", nil),
		(0x45, nil, nil, "€"),
	])

	/// Windows "US" layout (kbdus).
	private static let usTyped = table([
		(0x31, "1", "!", nil),
		(0x32, "2", "@", nil),
		(0x33, "3", "#", nil),
		(0x34, "4", "$", nil),
		(0x35, "5", "%", nil),
		(0x36, "6", "^", nil),
		(0x37, "7", "&", nil),
		(0x38, "8", "*", nil),
		(0x39, "9", "(", nil),
		(0x30, "0", ")", nil),
		(0xBD, "-", "_", nil),
		(0xBB, "=", "+", nil),
		(0xDB, "[", "{", nil),
		(0xDD, "]", "}", nil),
		(0xDC, "\\", "|", nil),
		(0xBA, ";", ":", nil),
		(0xDE, "'", "\"", nil),
		(0xC0, "`", "~", nil),
		(0xBC, ",", "<", nil),
		(0xBE, ".", ">", nil),
		(0xBF, "/", "?", nil),
	])

	// The tables below are generated from Microsoft's layout tables (KLC files), not
	// written by hand. Letters are only listed for what AltGr adds to them.

	/// Windows "United Kingdom" layout (kbduk).
	private static let ukTyped = table([
		(0x31, "1", "!", nil),
		(0x32, "2", "\"", nil),
		(0x33, "3", "£", nil),
		(0x34, "4", "$", "€"),
		(0x35, "5", "%", nil),
		(0x36, "6", "^", nil),
		(0x37, "7", "&", nil),
		(0x38, "8", "*", nil),
		(0x39, "9", "(", nil),
		(0x30, "0", ")", nil),
		(0xBD, "-", "_", nil),
		(0xBB, "=", "+", nil),
		(0x45, nil, nil, "é"),
		(0x55, nil, nil, "ú"),
		(0x49, nil, nil, "í"),
		(0x4F, nil, nil, "ó"),
		(0xDB, "[", "{", nil),
		(0xDD, "]", "}", nil),
		(0x41, nil, nil, "á"),
		(0xBA, ";", ":", nil),
		(0xC0, "'", "@", nil),
		(0xDF, "`", "¬", "¦"),
		(0xDE, "#", "~", "\\"),
		(0xBC, ",", "<", nil),
		(0xBE, ".", ">", nil),
		(0xBF, "/", "?", nil),
		(0xDC, "\\", "|", nil),
	], shiftedAltGr: [
		(0x45, "É"),
		(0x55, "Ú"),
		(0x49, "Í"),
		(0x4F, "Ó"),
		(0x41, "Á"),
	])

	/// Windows "Canadian French" layout (kbdca).
	private static let canadianFrenchTyped = table([
		(0x31, "1", "!", "±"),
		(0x32, "2", "\"", "@"),
		(0x33, "3", "/", "£"),
		(0x34, "4", "$", "¢"),
		(0x35, "5", "%", "¤"),
		(0x36, "6", "?", "¬"),
		(0x37, "7", "&", "¦"),
		(0x38, "8", "*", "²"),
		(0x39, "9", "(", "³"),
		(0x30, "0", ")", "¼"),
		(0xBD, "-", "_", "½"),
		(0xBB, "=", "+", "¾"),
		(0x45, nil, nil, "€"),
		(0x4F, nil, nil, "§"),
		(0x50, nil, nil, "¶"),
		(0xDB, "^", "^", "["),
		(0xDD, "¸", "¨", "]"),
		(0xBA, ";", ":", "~"),
		(0xC0, "`", "`", "{"),
		(0xDE, "#", "|", "\\"),
		(0xDC, "<", ">", "}"),
		(0x4D, nil, nil, "µ"),
		(0xBC, ",", "'", "¯"),
		(0xBE, ".", ".", nil),
		(0xBF, "é", "É", "´"),
		(0xE2, "«", "»", "°"),
	])

	/// Windows "Belgian French" layout (kbdbe).
	private static let belgianTyped = table([
		(0x31, "&", "1", "|"),
		(0x32, "é", "2", "@"),
		(0x33, "\"", "3", "#"),
		(0x34, "'", "4", "{"),
		(0x35, "(", "5", "["),
		(0x36, "§", "6", "^"),
		(0x37, "è", "7", nil),
		(0x38, "!", "8", nil),
		(0x39, "ç", "9", "{"),
		(0x30, "à", "0", "}"),
		(0xDB, ")", "°", nil),
		(0xBD, "-", "_", nil),
		(0x45, nil, nil, "€"),
		(0xDD, "^", "¨", "["),
		(0xBA, "$", "*", "]"),
		(0xC0, "ù", "%", "´"),
		(0xDE, "²", "³", nil),
		(0xDC, "µ", "£", "`"),
		(0xBC, ",", "?", nil),
		(0xBE, ";", ".", nil),
		(0xBF, ":", "/", nil),
		(0xBB, "=", "+", "~"),
		(0xE2, "<", ">", "\\"),
	])

	/// Windows "Swiss French" layout (kbdsf).
	private static let swissFrenchTyped = table([
		(0x31, "1", "+", "¦"),
		(0x32, "2", "\"", "@"),
		(0x33, "3", "*", "#"),
		(0x34, "4", "ç", "°"),
		(0x35, "5", "%", "§"),
		(0x36, "6", "&", "¬"),
		(0x37, "7", "/", "|"),
		(0x38, "8", "(", "¢"),
		(0x39, "9", ")", nil),
		(0x30, "0", "=", nil),
		(0xDB, "'", "?", "´"),
		(0xDD, "^", "`", "~"),
		(0x45, nil, nil, "€"),
		(0xBA, "è", "ü", "["),
		(0xC0, "¨", "!", "]"),
		(0xDE, "é", "ö", nil),
		(0xDC, "à", "ä", "{"),
		(0xBF, "§", "°", nil),
		(0xDF, "$", "£", "}"),
		(0xBC, ",", ";", nil),
		(0xBE, ".", ":", nil),
		(0xBD, "-", "_", nil),
		(0xE2, "<", ">", "\\"),
	])

	/// Windows "German" layout (kbdgr).
	private static let germanTyped = table([
		(0x31, "1", "!", nil),
		(0x32, "2", "\"", "²"),
		(0x33, "3", "§", "³"),
		(0x34, "4", "$", nil),
		(0x35, "5", "%", nil),
		(0x36, "6", "&", nil),
		(0x37, "7", "/", "{"),
		(0x38, "8", "(", "["),
		(0x39, "9", ")", "]"),
		(0x30, "0", "=", "}"),
		(0xDB, "ß", "?", "\\"),
		(0xDD, "´", "`", nil),
		(0x51, nil, nil, "@"),
		(0x45, nil, nil, "€"),
		(0xBA, "ü", "Ü", nil),
		(0xBB, "+", "*", "~"),
		(0xC0, "ö", "Ö", nil),
		(0xDE, "ä", "Ä", nil),
		(0xDC, "^", "°", nil),
		(0xBF, "#", "'", nil),
		(0x4D, nil, nil, "µ"),
		(0xBC, ",", ";", nil),
		(0xBE, ".", ":", nil),
		(0xBD, "-", "_", nil),
		(0xE2, "<", ">", "|"),
	], shiftedAltGr: [
		(0xDB, "ẞ"),
	])

	/// Windows "Spanish" layout (kbdsp).
	private static let spanishTyped = table([
		(0x31, "1", "!", "|"),
		(0x32, "2", "\"", "@"),
		(0x33, "3", "·", "#"),
		(0x34, "4", "$", "~"),
		(0x35, "5", "%", "€"),
		(0x36, "6", "&", "¬"),
		(0x37, "7", "/", nil),
		(0x38, "8", "(", nil),
		(0x39, "9", ")", nil),
		(0x30, "0", "=", nil),
		(0xDB, "'", "?", nil),
		(0xDD, "¡", "¿", nil),
		(0x45, nil, nil, "€"),
		(0xBA, "`", "^", "["),
		(0xBB, "+", "*", "]"),
		(0xC0, "ñ", "Ñ", nil),
		(0xDE, "´", "¨", "{"),
		(0xDC, "º", "ª", "\\"),
		(0xBF, "ç", "Ç", "}"),
		(0xBC, ",", ";", nil),
		(0xBE, ".", ":", nil),
		(0xBD, "-", "_", nil),
		(0xE2, "<", ">", nil),
	])

	/// Windows "Italian" layout (kbdit).
	private static let italianTyped = table([
		(0x31, "1", "!", nil),
		(0x32, "2", "\"", nil),
		(0x33, "3", "£", nil),
		(0x34, "4", "$", nil),
		(0x35, "5", "%", "€"),
		(0x36, "6", "&", nil),
		(0x37, "7", "/", nil),
		(0x38, "8", "(", nil),
		(0x39, "9", ")", nil),
		(0x30, "0", "=", nil),
		(0xDB, "'", "?", nil),
		(0xDD, "ì", "^", nil),
		(0x45, nil, nil, "€"),
		(0xBA, "è", "é", "["),
		(0xBB, "+", "*", "]"),
		(0xC0, "ò", "ç", "@"),
		(0xDE, "à", "°", "#"),
		(0xDC, "\\", "|", nil),
		(0xBF, "ù", "§", nil),
		(0xBC, ",", ";", nil),
		(0xBE, ".", ":", nil),
		(0xBD, "-", "_", nil),
		(0xE2, "<", ">", nil),
	], shiftedAltGr: [
		(0xBA, "{"),
		(0xBB, "}"),
	])
}

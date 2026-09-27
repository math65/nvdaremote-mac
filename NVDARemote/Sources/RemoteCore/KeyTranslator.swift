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
	case us

	public var label: String {
		switch self {
		case .french: localized("French (AZERTY)")
		case .us: localized("US (QWERTY)")
		}
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

	public init(nvdaKey: NVDAKeyChoice = .capsLock, pcLayout: PCLayout = .french) {
		self.nvdaKey = nvdaKey
		self.pcLayout = pcLayout
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
		case .us: Self.usPunctuation
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
}

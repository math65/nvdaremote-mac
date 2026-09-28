import Carbon.HIToolbox
import Foundation

/// Characters produced by each key with the Mac's active keyboard layout.
///
/// The table is read once, then reused: the keyboard tap callback must stay fast.
/// Call `reload()` whenever the user may have changed layouts, for example each
/// time control switches to the PC.
@MainActor
public final class MacKeyboardLayout {
	private var cache: [UInt16: KeyTranslator.Characters?] = [:]
	private var layoutData: Data?
	/// The active layout's identifier, such as "com.apple.keylayout.French".
	public private(set) var inputSourceID: String?

	public init() {
		reload()
	}

	public func reload() {
		cache.removeAll()
		layoutData = nil
		inputSourceID = nil
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
		if let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
			inputSourceID = Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
		}
		guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
		layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
	}

	public func characters(for keyCode: UInt16) -> KeyTranslator.Characters? {
		if let cached = cache[keyCode] {
			return cached
		}
		let result = translate(keyCode)
		cache[keyCode] = result
		return result
	}

	private func translate(_ keyCode: UInt16) -> KeyTranslator.Characters? {
		guard let plain = string(for: keyCode, modifiers: 0), !plain.isEmpty else { return nil }
		let shifted = string(for: keyCode, modifiers: UInt32(shiftKey >> 8) & 0xFF) ?? ""
		return KeyTranslator.Characters(plain: plain, shifted: shifted)
	}

	private func string(for keyCode: UInt16, modifiers: UInt32) -> String? {
		guard let layoutData else { return nil }
		return layoutData.withUnsafeBytes { buffer -> String? in
			guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
			var deadKeyState: UInt32 = 0
			var length = 0
			var characters = [UniChar](repeating: 0, count: 4)
			let status = UCKeyTranslate(
				layout,
				keyCode,
				UInt16(kUCKeyActionDown),
				modifiers,
				UInt32(LMGetKbdType()),
				OptionBits(kUCKeyTranslateNoDeadKeysMask),
				&deadKeyState,
				characters.count,
				&length,
				&characters,
			)
			guard status == noErr, length > 0 else { return nil }
			let string = String(utf16CodeUnits: characters, count: length)
			// Keys that produce no character return control characters: ignore them.
			return string.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control } ? nil : string
		}
	}
}

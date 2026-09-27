import Carbon.HIToolbox
import Foundation

/// Caractères produits par chaque touche selon la disposition active du Mac.
///
/// La table est lue une fois, puis réutilisée : le rappel du tap clavier doit rester rapide.
/// Appeler `reload()` quand l'utilisateur a pu changer de disposition, par exemple à
/// chaque passage en contrôle du PC.
@MainActor
public final class MacKeyboardLayout {
	private var cache: [UInt16: KeyTranslator.Characters?] = [:]
	private var layoutData: Data?

	public init() {
		reload()
	}

	public func reload() {
		cache.removeAll()
		layoutData = nil
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
			let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
		else { return }
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
			// Les touches muettes renvoient des caractères de contrôle : on les ignore.
			return string.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control } ? nil : string
		}
	}
}

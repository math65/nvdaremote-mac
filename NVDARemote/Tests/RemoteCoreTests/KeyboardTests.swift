import CoreGraphics
import Foundation
import Testing

@testable import RemoteCore

@Suite struct KeyTranslatorTests {
	typealias Chars = KeyTranslator.Characters

	let french = KeyTranslator(nvdaKey: .capsLock, pcLayout: .french)

	/// Measured in docs/keyboard-measurements.md: key code 12, "ANSI_Q", produces "a" on AZERTY.
	@Test func lettersFollowProducedCharacter() {
		#expect(french.translate(keyCode: 12, characters: Chars(plain: "a", shifted: "A")) == WindowsKey(0x41))
		#expect(french.translate(keyCode: 0, characters: Chars(plain: "q", shifted: "Q")) == WindowsKey(0x51))
		#expect(french.translate(keyCode: 13, characters: Chars(plain: "z", shifted: "Z")) == WindowsKey(0x5A))
	}

	@Test func azertyTopRowGivesDigits() {
		#expect(french.translate(keyCode: 18, characters: Chars(plain: "&", shifted: "1")) == WindowsKey(0x31))
		#expect(french.translate(keyCode: 19, characters: Chars(plain: "é", shifted: "2")) == WindowsKey(0x32))
		#expect(french.translate(keyCode: 29, characters: Chars(plain: "à", shifted: "0")) == WindowsKey(0x30))
		#expect(french.translate(keyCode: 22, characters: Chars(plain: "§", shifted: "6")) == WindowsKey(0x36))
	}

	@Test func frenchPunctuationByCharacter() {
		#expect(french.translate(keyCode: 46, characters: Chars(plain: ",", shifted: "?")) == WindowsKey(0xBC))
		#expect(french.translate(keyCode: 43, characters: Chars(plain: ";", shifted: ".")) == WindowsKey(0xBE))
		#expect(french.translate(keyCode: 47, characters: Chars(plain: ":", shifted: "/")) == WindowsKey(0xBF))
		#expect(french.translate(keyCode: 39, characters: Chars(plain: "ù", shifted: "%")) == WindowsKey(0xC0))
		#expect(french.translate(keyCode: 24, characters: Chars(plain: "-", shifted: "_")) == WindowsKey(0x36))
		#expect(french.translate(keyCode: 33, characters: Chars(plain: "^", shifted: "¨")) == WindowsKey(0xDD))
	}

	@Test func unknownCharacterFallsBackToPosition() {
		// "@" has no unmodified key on an AZERTY PC: use the key at the same position.
		#expect(french.translate(keyCode: 50, characters: Chars(plain: "@", shifted: "#")) == WindowsKey(0xDE))
		#expect(french.translate(keyCode: 200, characters: Chars(plain: "@", shifted: "#")) == nil)
	}

	@Test func usLayout() {
		let us = KeyTranslator(nvdaKey: .capsLock, pcLayout: .us)
		#expect(us.translate(keyCode: 44, characters: Chars(plain: "/", shifted: "?")) == WindowsKey(0xBF))
		#expect(us.translate(keyCode: 18, characters: Chars(plain: "1", shifted: "!")) == WindowsKey(0x31))
		#expect(us.translate(keyCode: 41, characters: Chars(plain: ";", shifted: ":")) == WindowsKey(0xBA))
	}

	@Test func navigationAndModifiers() {
		#expect(french.translate(keyCode: 126, characters: nil) == WindowsKey(0x26, extended: true))
		#expect(french.translate(keyCode: 115, characters: nil) == WindowsKey(0x24, extended: true))
		#expect(french.translate(keyCode: MacKeyCode.command, characters: nil) == WindowsKey(0x5B, extended: true))
		#expect(french.translate(keyCode: MacKeyCode.option, characters: nil) == WindowsKey(0xA4))
		#expect(french.translate(keyCode: MacKeyCode.control, characters: nil) == WindowsKey(0xA2))
		#expect(french.translate(keyCode: MacKeyCode.returnKey, characters: nil) == WindowsKey(0x0D))
		// Numeric keypad with Num Lock off: numpad8 = non-extended Up.
		#expect(french.translate(keyCode: 91, characters: Chars(plain: "8", shifted: "8")) == WindowsKey(0x26))
	}

	@Test func nvdaKeyChoices() {
		#expect(french.translate(keyCode: MacKeyCode.f18, characters: nil) == .insert)
		#expect(french.translate(keyCode: MacKeyCode.capsLock, characters: nil) == nil)

		let option = KeyTranslator(nvdaKey: .rightOption, pcLayout: .french)
		#expect(option.translate(keyCode: MacKeyCode.rightOption, characters: nil) == .insert)
		#expect(option.translate(keyCode: MacKeyCode.f18, characters: nil) == WindowsKey(0x81))

		let fn = KeyTranslator(nvdaKey: .fn, pcLayout: .french)
		#expect(fn.translate(keyCode: MacKeyCode.function, characters: nil) == .insert)
		#expect(fn.translate(keyCode: MacKeyCode.globe, characters: nil) == nil)
		#expect(french.translate(keyCode: MacKeyCode.function, characters: nil) == nil)
	}
}

@Suite struct KeyboardCaptureTests {
	@Test func modifierStateUsesDeviceMasks() {
		let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)
		#expect(KeyboardCapture.isModifierPressed(MacKeyCode.control, flags: leftControl) == true)
		#expect(KeyboardCapture.isModifierPressed(MacKeyCode.rightControl, flags: leftControl) == false)
		#expect(KeyboardCapture.isModifierPressed(MacKeyCode.function, flags: .maskSecondaryFn) == true)
		#expect(KeyboardCapture.isModifierPressed(MacKeyCode.function, flags: []) == false)
		#expect(KeyboardCapture.isModifierPressed(MacKeyCode.capsLock, flags: []) == nil)
	}

	@Test func toggleShortcutMatchesExactModifiers() {
		let shortcut = GlobalCommand.toggleControl.defaultShortcut
		#expect(shortcut.matches(keyCode: 15, flags: [.maskControl, .maskCommand]))
		// Unrelated flags, such as fn or numeric keypad, do not interfere.
		#expect(shortcut.matches(keyCode: 15, flags: [.maskControl, .maskCommand, .maskSecondaryFn]))
		#expect(!shortcut.matches(keyCode: 15, flags: [.maskControl, .maskCommand, .maskShift]))
		#expect(!shortcut.matches(keyCode: 15, flags: [.maskControl]))
		#expect(shortcut.displayName(characters: .init(plain: "r", shifted: "R")) == "Ctrl+Cmd+R")
		#expect(shortcut.spokenName(characters: .init(plain: "r", shifted: "R")) == "Control-Command-R")
	}

	@Test func keyMessage() throws {
		let data = OutgoingMessage.key(.insert, pressed: true)
		let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
		#expect(object == ["type": "key", "vk_code": 0x2D, "extended": true, "pressed": true])
	}
}

@MainActor
@Suite struct KeyboardCaptureFlowTests {
	typealias Event = KeyboardCapture.KeyEvent

	let capture = KeyboardCapture()
	let recorder = Recorder()

	final class Recorder {
		var keys: [(WindowsKey, Bool)] = []
		var commands: [GlobalCommand] = []
	}

	init() {
		let recorder = recorder
		capture.onKey = { recorder.keys.append(($0, $1)) }
		capture.onCommand = { recorder.commands.append($0) }
	}

	var sent: [String] {
		recorder.keys.map { "\(String($0.0.vk, radix: 16))\($0.1 ? "↓" : "↑")" }
	}

	@Test func localModePassesEverythingButToggle() {
		#expect(!capture.handle(Event(type: .keyDown, keyCode: 126)))
		#expect(!capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.control, flags: .maskControl)))
		#expect(capture.handle(Event(type: .keyDown, keyCode: 15, flags: [.maskControl, .maskCommand])))
		#expect(capture.handle(Event(type: .keyDown, keyCode: 15, flags: [.maskControl, .maskCommand], isRepeat: true)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 15)))
		#expect(capture.handle(Event(type: .keyDown, keyCode: 8, flags: [.maskControl, .maskCommand])))
		#expect(recorder.commands == [.toggleControl, .pushClipboard])
		#expect(recorder.keys.isEmpty)
	}

	@Test func remoteModeSendsAndSwallows() {
		capture.setRemote(true)
		let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)
		#expect(capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.control, flags: leftControl)))
		#expect(capture.handle(Event(type: .keyDown, keyCode: 115)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 115)))
		#expect(capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.control, flags: [])))
		#expect(sent == ["a2↓", "24↓", "24↑", "a2↑"])
	}

	/// Right after switching, Control and Command are still held: their release goes back to the Mac.
	@Test func releaseOfKeyNeverSentGoesBackToMac() {
		capture.setRemote(true)
		#expect(!capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.command, flags: [])))
		#expect(!capture.handle(Event(type: .keyUp, keyCode: 126)))
		#expect(recorder.keys.isEmpty)
	}

	@Test func returningToMacReleasesHeldKeys() {
		capture.setRemote(true)
		_ = capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.option, flags: CGEventFlags(rawValue: 0x80020)))
		_ = capture.handle(Event(type: .keyDown, keyCode: 126))
		capture.setRemote(false)
		#expect(sent == ["a4↓", "26↓", "ff↓", "ff↑", "26↑", "a4↑"])
		// Nothing more is sent afterwards.
		#expect(!capture.handle(Event(type: .keyUp, keyCode: 126)))
		#expect(recorder.keys.count == 6)
	}

	@Test func capsLockIsAlwaysSwallowedInRemoteMode() {
		capture.setRemote(true)
		#expect(capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.capsLock, flags: .maskAlphaShift)))
		#expect(recorder.keys.isEmpty)
	}
}

@Suite struct SoundPlayerTests {
	@Test func remotePathKeepsOnlySafeBaseName() {
		#expect(SoundPlayer.soundName(fromRemotePath: #"C:\Program Files\NVDA\waves\browseMode.wav"#) == "browseMode")
		#expect(SoundPlayer.soundName(fromRemotePath: "focusMode.WAV") == "focusMode")
		#expect(SoundPlayer.soundName(fromRemotePath: #"C:\x\..\"#) == nil)
		#expect(SoundPlayer.soundName(fromRemotePath: "") == nil)
	}

	@Test func nvdaSoundsAreBundled() {
		for name in ["browseMode", "focusMode", "error", "connected", "clipboardReceive"] {
			#expect(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") != nil)
		}
	}

	@Test func clipboardMessages() throws {
		#expect(try IncomingMessage.parse(Data(#"{"type":"set_clipboard_text","text":"é\n2"}"#.utf8))
			== .clipboardText("é\n2"))
		let object = try #require(
			JSONSerialization.jsonObject(with: OutgoingMessage.clipboardText("x")) as? [String: String])
		#expect(object == ["type": "set_clipboard_text", "text": "x"])
	}
}

@Suite struct CapsLockRemapTests {
	@Test func readsPerDeviceTable() {
		let none = """
			RegistryID  Key                   Value
			100000c66   UserKeyMapping   (null)
			100000977   UserKeyMapping   (null)
			"""
		#expect(!CapsLockRemap.hasMappings(none))
		#expect(!CapsLockRemap.hasMappings("(null)\n"))
		// After removal, each device keeps an empty list.
		#expect(!CapsLockRemap.hasMappings("""
			RegistryID  Key                   Value
			100000c66   UserKeyMapping   (
			)
			"""))
		let some = """
			RegistryID  Key                   Value
			100000c66   UserKeyMapping   (null)
			100000977   UserKeyMapping   (
			    {
			    HIDKeyboardModifierMappingDst = 30064771181;
			    HIDKeyboardModifierMappingSrc = 30064771129;
			}
			)
			"""
		#expect(CapsLockRemap.hasMappings(some))
	}
}

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

	/// The "!" key of an AZERTY Mac types "!" without Shift and "8" with Shift, on the PC too.
	@Test func shiftDecidesBetweenPunctuationAndDigit() {
		let bang = Chars(plain: "!", shifted: "8")
		#expect(french.translate(keyCode: 28, characters: bang) == WindowsKey(0xDF))
		#expect(french.translate(keyCode: 28, characters: bang, shift: true) == WindowsKey(0x38))
		let ampersand = Chars(plain: "&", shifted: "1")
		#expect(french.translate(keyCode: 18, characters: ampersand) == WindowsKey(0x31))
		#expect(french.translate(keyCode: 18, characters: ampersand, shift: true) == WindowsKey(0x31))
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
		#expect(french.translate(keyCode: 10, characters: Chars(plain: "@", shifted: "#")) == WindowsKey(0xDE))
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
		#expect(shortcut.displayName(characters: .init(plain: "r", shifted: "R")) == "⌃⌘R")
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
		#expect(CapsLockRemap.isOurMapping("HIDKeyboardModifierMappingDst = 30064771181;\nHIDKeyboardModifierMappingSrc = 30064771129;"))
		#expect(!CapsLockRemap.isOurMapping("HIDKeyboardModifierMappingDst = 30064771300;\nHIDKeyboardModifierMappingSrc = 30064771129;"))
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

@Suite struct BrailleTests {
	@Test func typedCellsFollowNVDABindings() {
		#expect(BrailleGesture.typed(dots: 0) == .space)
		#expect(BrailleGesture.typed(dots: 0x40) == .eraseLastCell)
		#expect(BrailleGesture.typed(dots: 0x80) == .enter)
		#expect(BrailleGesture.typed(dots: 0xC0) == .translate)
		#expect(BrailleGesture.typed(dots: 0x13) == .dots(0x13))
	}

	@Test func displayMessage() throws {
		#expect(try IncomingMessage.parse(Data(#"{"type":"display","cells":[19,0,255]}"#.utf8))
			== .display(cells: [19, 0, 255]))
	}

	/// The PC rebuilds a BrailleInputGesture from these fields and runs `scriptPath`.
	@Test func brailleInputMessages() throws {
		func decode(_ gesture: BrailleGesture) throws -> [String: Any] {
			try #require(JSONSerialization.jsonObject(with: OutgoingMessage.brailleInput(gesture)) as? [String: Any])
		}
		func script(_ fields: [String: Any]) -> [String]? { fields["scriptPath"] as? [String] }

		let routing = try decode(.routing(cell: 12))
		#expect(routing["type"] as? String == "braille_input")
		#expect(script(routing) == ["globalCommands", "GlobalCommands", "braille_routeTo"])
		#expect(routing["cellIndexes"] as? [Int] == [12])
		#expect(routing["routingIndex"] as? Int == 12)
		#expect(routing["source"] as? String == "mac")

		let dots = try decode(.dots(0x13))
		#expect(script(dots) == ["globalCommands", "GlobalCommands", "braille_dots"])
		#expect(dots["dots"] as? Int == 0x13)
		#expect(dots["space"] as? Bool == false)

		#expect(try decode(.space)["space"] as? Bool == true)
		#expect(script(try decode(.scrollForward)) == ["globalCommands", "GlobalCommands", "braille_scrollForward"])
	}

	typealias Usage = HIDBrailleKeys.Usage

	/// The bindings of NVDA's hidBrailleStandard driver.
	@Test func displayKeysFollowNVDABindings() {
		func gesture(_ keys: Set<UInt32>, routers: [Int] = []) -> BrailleGesture? {
			HIDBrailleKeys.gesture(keys: keys, routerCells: routers)
		}
		#expect(gesture([], routers: [12]) == .routing(cell: 12))
		// Several router keys: NVDA selects from the first to the last cell.
		#expect(gesture([], routers: [20, 4]) == .selectRange(cells: [4, 20]))
		#expect(gesture([Usage.panLeft]) == .command("braille_scrollBack", id: "panLeft"))
		#expect(gesture([Usage.rockerDown]) == .command("braille_scrollForward", id: "rockerDown"))
		#expect(gesture([Usage.dpadLeft]) == .command("kb:leftArrow", id: "dpadLeft"))
		#expect(gesture([Usage.joystickCenter]) == .command("kb:enter", id: "joystickCenter"))
		// Dots 1, 2 and 5 typed alone: an "h".
		#expect(gesture([Usage.dot1, Usage.dot1 + 1, Usage.dot1 + 4]) == .dots(0x13))
		#expect(gesture([Usage.dot1 + 6]) == .eraseLastCell)
		#expect(gesture([Usage.space]) == .space)
		#expect(gesture([Usage.leftSpace]) == .space)
		// Space with dots 1: up arrow. Space with dots 1, 3, 4, 5: NVDA menu.
		#expect(gesture([Usage.space, Usage.dot1]) == .command("kb:upArrow", id: "dot1+space"))
		#expect(gesture([Usage.space, Usage.dot1, Usage.dot1 + 2, Usage.dot1 + 3, Usage.dot1 + 4])
			== .command("showGui", id: "dot1+dot3+dot4+dot5+space"))
		#expect(gesture([Usage.space, Usage.dot1 + 3, Usage.dot1 + 5]) == .command("kb:tab", id: "dot4+dot6+space"))
		// Unbound chords do nothing.
		#expect(gesture([Usage.space, Usage.dot1 + 1]) == nil)
		#expect(gesture([Usage.panLeft, Usage.panRight]) == nil)
		#expect(gesture([Usage.dot1], routers: [3]) == nil)
	}

	@Test func commandGestureNamesTheScript() throws {
		let fields = try #require(JSONSerialization.jsonObject(
			with: OutgoingMessage.brailleInput(.command("kb:alt+tab", id: "dot2+dot3+dot4+dot5+space"))) as? [String: Any])
		#expect(fields["scriptPath"] as? [String] == ["globalCommands", "GlobalCommands", "kb:alt+tab"])
		#expect(fields["id"] as? String == "dot2+dot3+dot4+dot5+space")

		let range = try #require(JSONSerialization.jsonObject(
			with: OutgoingMessage.brailleInput(.selectRange(cells: [4, 20]))) as? [String: Any])
		#expect(range["scriptPath"] as? [String] == ["globalCommands", "GlobalCommands", "braille_selectRange"])
		#expect(range["cellIndexes"] as? [Int] == [4, 20])
		#expect(range["routingIndex"] == nil)
	}

	@Test func brailleInfoMessage() throws {
		let object = try #require(JSONSerialization.jsonObject(with: OutgoingMessage.brailleInfo(name: "voiceOver", numCells: 40)) as? [String: AnyHashable])
		#expect(object == ["type": "set_braille_info", "name": "voiceOver", "numCells": 40])
	}
}

/// Typing text across layouts: the user keeps the Mac's layout, the PC gets the same
/// characters whenever its own layout can type them.
@MainActor @Suite struct CrossLayoutTypingTests {
	typealias Event = KeyboardCapture.KeyEvent
	typealias Chars = KeyTranslator.Characters

	let capture = KeyboardCapture()
	let recorder = KeyboardCaptureFlowTests.Recorder()

	/// A few keys of a French AZERTY Mac, by key code.
	static let azertyMac: [UInt16: Chars] = [
		12: Chars(plain: "a", shifted: "A"),
		18: Chars(plain: "&", shifted: "1"),
		19: Chars(plain: "é", shifted: "2"),
		10: Chars(plain: "@", shifted: "#"),
		47: Chars(plain: ":", shifted: "/"),
		28: Chars(plain: "!", shifted: "8"),
		22: Chars(plain: "§", shifted: "6"),
	]

	init() {
		let recorder = recorder
		capture.onKey = { recorder.keys.append(($0, $1)) }
		capture.characters = { Self.azertyMac[$0] }
		capture.setRemote(true)
	}

	var sent: [String] {
		recorder.keys.map { "\(String($0.0.vk, radix: 16))\($0.1 ? "↓" : "↑")" }
	}

	let leftShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x0002)

	func pressShift() {
		_ = capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.shift, flags: leftShift))
	}

	@Test func defaultPCLayoutFollowsTheMacKeyboard() {
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.French") == .french)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.French-PC") == .french)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.ABC-AZERTY") == .french)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.Belgian") == .french)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.SwissFrench") == .us)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.US") == .us)
		#expect(PCLayout(matchingMacLayout: "com.apple.keylayout.British") == .us)
		#expect(PCLayout(matchingMacLayout: nil) == .us)
	}

	@Test func tablesTypeEachCharacterOnce() {
		let us = KeyTranslator(pcLayout: .us)
		#expect(us.typedKey(for: "1") == TypedKey(0x31))
		#expect(us.typedKey(for: "!") == TypedKey(0x31, shift: true))
		#expect(us.typedKey(for: ":") == TypedKey(0xBA, shift: true))
		#expect(us.typedKey(for: "é") == nil)
		let french = KeyTranslator(pcLayout: .french)
		#expect(french.typedKey(for: "1") == TypedKey(0x31, shift: true))
		#expect(french.typedKey(for: "@") == TypedKey(0x30, altGr: true))
		#expect(french.typedKey(for: "§") == TypedKey(0xDF, shift: true))
		// The dead key comes first, so "^" then "e" still gives "ê".
		#expect(french.typedKey(for: "^") == TypedKey(0xDD))
	}

	/// Shift-& types "1" on an AZERTY Mac: a US PC gets "1" without Shift.
	@Test func azertyDigitOnUSPC() {
		capture.translator.pcLayout = .us
		pressShift()
		#expect(capture.handle(Event(type: .keyDown, keyCode: 18, flags: leftShift)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 18, flags: leftShift)))
		#expect(sent == ["a0↓", "a0↑", "31↓", "31↑", "a0↓"])
	}

	/// "&" alone on the Mac needs Shift on a US PC.
	@Test func azertySymbolOnUSPC() {
		capture.translator.pcLayout = .us
		#expect(capture.handle(Event(type: .keyDown, keyCode: 18)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 18)))
		#expect(sent == ["a0↓", "37↓", "37↑", "a0↑"])
	}

	/// "@" is a plain key on an AZERTY Mac, AltGr-à on a French PC.
	@Test func altGrOnFrenchPC() {
		capture.translator.pcLayout = .french
		#expect(capture.handle(Event(type: .keyDown, keyCode: 10)))
		#expect(sent == ["a2↓", "a5↓", "30↓", "30↑", "a5↑", "a2↑"])
	}

	/// Where both layouts agree, the key is held and released as usual.
	@Test func sameCharacterSameModifiers() {
		capture.translator.pcLayout = .french
		#expect(capture.handle(Event(type: .keyDown, keyCode: 28)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 28)))
		pressShift()
		#expect(capture.handle(Event(type: .keyDown, keyCode: 18, flags: leftShift)))
		#expect(sent == ["df↓", "df↑", "a0↓", "31↓"])
	}

	/// "§", a plain key on the Mac, is Shift-! on a French PC: the former limitation is gone.
	@Test func sectionSignOnFrenchPC() {
		capture.translator.pcLayout = .french
		#expect(capture.handle(Event(type: .keyDown, keyCode: 22)))
		#expect(sent == ["a0↓", "df↓", "df↑", "a0↑"])
	}

	/// A US PC has no "é": nothing is typed rather than a wrong character.
	@Test func missingCharacterSendsNothing() {
		capture.translator.pcLayout = .us
		#expect(capture.handle(Event(type: .keyDown, keyCode: 19)))
		#expect(capture.handle(Event(type: .keyUp, keyCode: 19)))
		#expect(recorder.keys.isEmpty)
	}

	/// With Control held it is a command: the key follows its position, modifiers untouched.
	@Test func commandsKeepTheUsersModifiers() {
		capture.translator.pcLayout = .us
		let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)
		_ = capture.handle(Event(type: .flagsChanged, keyCode: MacKeyCode.control, flags: leftControl))
		#expect(capture.handle(Event(type: .keyDown, keyCode: 18, flags: leftControl)))
		#expect(sent == ["a2↓", "31↓"])
	}

	/// Letters are sent as themselves, Shift included, whatever the PC's layout.
	@Test func lettersPassThrough() {
		capture.translator.pcLayout = .us
		pressShift()
		#expect(capture.handle(Event(type: .keyDown, keyCode: 12, flags: leftShift)))
		#expect(sent == ["a0↓", "41↓"])
	}
}

// Global keyboard capture test bench — NVDA Remote for macOS project.
//
// Questions this program answers:
//   1. Which macOS permission is actually required to swallow keystrokes?
//   2. Does a CGEventTap see, and can it swallow, Command+Tab and Command+Space?
//   3. Does it see VoiceOver commands (Control+Option+arrow)?
//   4. What happens to Caps Lock? And to the fn key?
//   5. How does the physical key code relate to the character produced on an
//      AZERTY keyboard? This is the basis for the table to Windows key codes.
//
// During the capture phase, VoiceOver stops responding: the tap swallows
// everything. Instructions are therefore spoken aloud, and the report is only
// printed once the keyboard has been released.
//
// Emergency exits: Escape always passes through and ends the test; a watchdog
// releases the keyboard after 90 seconds no matter what; and killing the
// process destroys the tap along with it.

import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

// MARK: - Utilities

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

// MARK: - Physical key names (ANSI positions)

/// Position names, as defined by Carbon. On an AZERTY keyboard, the key at the
/// "ANSI Q" position produces an "a": this is exactly the gap this bench
/// highlights.
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
	// Globe / fn key on recent Macs, missing from the Carbon constants.
	179: "Globe (fn)",
	// Usual targets when Caps Lock is remapped with hidutil.
	79: "F18", 80: "F19", 90: "F20",
]

func keyName(_ code: Int64) -> String {
	keyNames[code] ?? "unknown(\(code))"
}

func describeFlags(_ flags: CGEventFlags) -> String {
	var parts: [String] = []
	if flags.contains(.maskCommand) { parts.append("cmd") }
	if flags.contains(.maskAlternate) { parts.append("option") }
	if flags.contains(.maskControl) { parts.append("ctrl") }
	if flags.contains(.maskShift) { parts.append("shift") }
	if flags.contains(.maskAlphaShift) { parts.append("CAPSLOCK") }
	if flags.contains(.maskSecondaryFn) { parts.append("fn") }
	if flags.contains(.maskNumericPad) { parts.append("numpad") }
	return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

// MARK: - Event recording

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
	/// Start of the current step's window, used to sort events afterwards.
	var stepStart: Double = 0

	func eventsSinceStepStart() -> [Captured] {
		events.filter { $0.time >= stepStart }
	}
}

let recorder = Recorder()

// MARK: - The tap

/// The callback is a C function pointer: it cannot capture context, hence the
/// use of global objects.
func tapCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
	// The system disables a tap that is too slow or disrupted: it must be re-enabled.
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
	default: typeName = "other(\(type.rawValue))"
	}

	// Emergency exit: Escape is never swallowed and ends the test.
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

	// Everything is swallowed except Escape.
	return isEscape ? Unmanaged.passUnretained(event) : nil
}

var globalTap: CFMachPort?

// MARK: - Speech to guide the test

let synth = AVSpeechSynthesizer()

/// The instructions are in English, so they are spoken with the best available
/// US English voice.
func instructionVoice() -> AVSpeechSynthesisVoice? {
	let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
	func rank(_ v: AVSpeechSynthesisVoice) -> Int {
		switch v.quality {
		case .premium: return 3
		case .enhanced: return 2
		default: return 1
		}
	}
	return candidates.max(by: { rank($0) < rank($1) }) ?? AVSpeechSynthesisVoice(language: "en-US")
}

let guideVoice = instructionVoice()
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
	u.voice = guideVoice
	u.preUtteranceDelay = 0
	u.postUtteranceDelay = 0
	speechDone = false
	synth.speak(u)
	if waitForEnd {
		pump(until: { speechDone }, timeout: 30)
	}
}

// MARK: - Permission check

title("Permissions")

let processName = ProcessInfo.processInfo.processName
let parentDescription = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
print("Process: \(processName)")
print("Frontmost application at launch: \(parentDescription)")
print("")
print("Important reminder: a command-line executable has no identity of its own")
print("as far as macOS is concerned. Permissions are attached to the application")
print("that launches it, i.e. the terminal in use. That terminal is what must be")
print("authorized, not this binary. The final app will have its own identity and")
print("will ask on its own behalf.")
print("")

let axTrusted = AXIsProcessTrusted()
print("Accessibility (allows MODIFYING and swallowing events): " +
	(axTrusted ? "granted" : "NOT granted"))

let listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
let listenText: String
switch listenAccess {
case kIOHIDAccessTypeGranted: listenText = "granted"
case kIOHIDAccessTypeDenied: listenText = "denied"
default: listenText = "never requested"
}
print("Input Monitoring (allows OBSERVING events): \(listenText)")

let mask =
	(1 << CGEventType.keyDown.rawValue) |
	(1 << CGEventType.keyUp.rawValue) |
	(1 << CGEventType.flagsChanged.rawValue)

// Two possible interception levels:
//   .cgSessionEventTap: at the session level, after privileged processes.
//   .cghidEventTap:     as close to the hardware as possible, so BEFORE VoiceOver.
// Since VoiceOver grabs Control+Option+arrow at the session level, HID mode
// tells us whether it can be bypassed without a DriverKit driver.
let useHIDTap = CommandLine.arguments.contains("--hid")
print("Requested interception level: " + (useHIDTap ? "HID (lowest)" : "session"))

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
	print("FAILURE: unable to create the tap.")
	print("")
	print("This is the expected result when the permission is missing, and it is")
	print("already a useful answer: macOS does require an explicit permission to")
	print("swallow keystrokes, and it cannot be bypassed.")
	print("")
	print("To continue, open System Settings, Privacy & Security, then add your")
	print("terminal under Accessibility and under Input Monitoring.")
	print("The terminal must then be relaunched for the permission to take effect.")
	exit(1)
}

globalTap = tap
print("")
print("Tap created successfully: the required permission is therefore already in place.")

// Check-only pass: the tap is never enabled, so the keyboard is never
// captured. Used to see where things stand without locking up the machine.
if CommandLine.arguments.contains("--check") {
	print("")
	print("Check mode: the tap was not enabled, your keyboard is untouched.")
	print("Run again without --check to go through the guided test.")
	exit(0)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Watchdog: the keyboard is released after 90 seconds no matter what.
let watchdogDeadline = now() + 90

func watchdogExpired() -> Bool {
	now() >= watchdogDeadline
}

// MARK: - Guided test

struct Step {
	let spoken: String
	let label: String
	let seconds: Double
	/// Check whether the frontmost application changed (proof that a system
	/// shortcut such as Command+Tab got through despite the tap).
	let checkFrontmost: Bool
}

/// Targeted test: can the arrow key be captured on its own, and does VoiceOver
/// grab it when combined with Control+Option?
let voiceOverSteps: [Step] = [
	Step(spoken: "Test one. Press the right arrow, on its own.",
	     label: "Right arrow alone", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test two. Press control option right arrow, together.",
	     label: "Control+Option+Right arrow", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test three. Press control option left arrow.",
	     label: "Control+Option+Left arrow", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test four. Press caps lock, then the letter A.",
	     label: "Caps Lock then letter", seconds: 6, checkFrontmost: false),
]

/// Dedicated test: does Caps Lock still toggle the system state?
/// The letter typed right after tells all: "a" means the toggle was
/// neutralized, "A" means it happened despite the tap.
let capsLockSteps: [Step] = [
	Step(spoken: "Test one. Press caps lock, then type the letter A.",
	     label: "Caps Lock then A, first try", seconds: 6, checkFrontmost: false),
	Step(spoken: "Test two. Press caps lock again, then type the letter A.",
	     label: "Caps Lock then A, second try", seconds: 6, checkFrontmost: false),
]

let fullSteps: [Step] = [
	Step(spoken: "Test one. Press the A key.",
	     label: "Single key", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test two. Press command tab.",
	     label: "Command+Tab", seconds: 5, checkFrontmost: true),
	Step(spoken: "Test three. Press command space.",
	     label: "Command+Space (Spotlight)", seconds: 5, checkFrontmost: true),
	Step(spoken: "Test four. Press control option right arrow, a VoiceOver command.",
	     label: "Control+Option+Arrow (VoiceOver)", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test five. Press caps lock, twice.",
	     label: "Caps Lock", seconds: 5, checkFrontmost: false),
	Step(spoken: "Test six. Press the function key, at the bottom left.",
	     label: "fn key", seconds: 4, checkFrontmost: false),
	Step(spoken: "Test seven. Type the letters A, Q, W and Z, one after the other.",
	     label: "Keyboard layout", seconds: 7, checkFrontmost: false),
]

let useVoiceOverSteps = CommandLine.arguments.contains("--voiceover")
let steps: [Step] = CommandLine.arguments.contains("--capslock")
	? capsLockSteps
	: (useVoiceOverSteps ? voiceOverSteps : fullSteps)

var results: [(step: Step, events: [Captured], frontBefore: String, frontAfter: String)] = []

say("Warning, I will capture the keyboard in five seconds. " +
	"VoiceOver will stop responding during the test. " +
	"\(steps.count) instructions will follow, one per key to try. " +
	"Escape ends everything at any time. Get your hands ready.")

let readyDeadline = now() + 5
pump(until: { now() >= readyDeadline }, timeout: 6)

say("The keyboard is now captured.")

for step in steps {
	if recorder.escapePressed || watchdogExpired() { break }

	let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
	say(step.spoken)

	recorder.stepStart = now()
	let deadline = now() + step.seconds
	pump(until: { now() >= deadline || recorder.escapePressed || watchdogExpired() },
	     timeout: step.seconds + 2)

	let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
	results.append((step, recorder.eventsSinceStepStart(), frontBefore, frontAfter))
}

// MARK: - Keyboard release

CGEvent.tapEnable(tap: tap, enable: false)
CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
globalTap = nil

say("Keyboard released. VoiceOver is back. The report is shown in the terminal.")

// MARK: - Report

title("Guided test results")

if recorder.escapePressed {
	print("Test interrupted by Escape. The steps reached are listed below.")
}
if watchdogExpired() {
	print("Watchdog triggered: the keyboard was released after 90 seconds.")
}

for result in results {
	print("")
	print("• \(result.step.label)")
	let keyDowns = result.events.filter { $0.type == "keyDown" && !$0.isRepeat }
	let flagChanges = result.events.filter { $0.type == "flagsChanged" }

	if result.events.isEmpty {
		print("  NO events captured. The tap did not see this key.")
	} else {
		for e in keyDowns {
			let charText = e.characters.isEmpty ? "no character" : "character \"\(e.characters)\""
			print("  keyDown  code \(e.keyCode) (\(keyName(e.keyCode)))  \(charText)  " +
				"modifiers \(describeFlags(e.flags))  " +
				(e.swallowed ? "swallowed" : "PASSED THROUGH"))
		}
		for e in flagChanges {
			print("  flagsChanged  code \(e.keyCode) (\(keyName(e.keyCode)))  " +
				"state \(describeFlags(e.flags))  " +
				(e.swallowed ? "swallowed" : "PASSED THROUGH"))
		}
		let others = result.events.count - keyDowns.count - flagChanges.count
		if others > 0 {
			print("  plus \(others) key-up or repeat event(s).")
		}
	}

	if result.step.checkFrontmost {
		if result.frontBefore == result.frontAfter {
			print("  Frontmost application unchanged (\(result.frontAfter)): " +
				"the system shortcut was successfully neutralized.")
		} else {
			print("  WARNING: frontmost application changed from \(result.frontBefore) to \(result.frontAfter). " +
				"The shortcut got through despite the tap.")
		}
	}
}

title("Summary")

let allEvents = recorder.events
print("Total events captured: \(allEvents.count).")
print("Times the system disabled the tap: \(recorder.tapDisabledCount).")

let distinctKeys = Set(allEvents.filter { $0.type == "keyDown" }.map { $0.keyCode })
print("Distinct keys seen: \(distinctKeys.count).")

let capsLockSeen = allEvents.contains { $0.keyCode == 57 }
print("Caps Lock seen by the tap: \(capsLockSeen ? "yes" : "no")")

let fnSeen = allEvents.contains { $0.keyCode == 63 || $0.flags.contains(.maskSecondaryFn) }
print("fn key seen by the tap: \(fnSeen ? "yes" : "no")")

title("Position to character mapping")
print("Useful for the table to Windows key codes: the code is positional,")
print("the character depends on the layout active on the Mac.")

var mapping: [Int64: String] = [:]
for e in allEvents where e.type == "keyDown" && !e.characters.isEmpty {
	mapping[e.keyCode] = e.characters
}
if mapping.isEmpty {
	print("No mapping recorded.")
} else {
	for (code, char) in mapping.sorted(by: { $0.key < $1.key }) {
		print("  code \(code) named \(keyName(code)) produces \"\(char)\"")
	}
}

title("End of keyboard bench")

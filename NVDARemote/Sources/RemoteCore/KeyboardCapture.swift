import ApplicationServices
import CoreGraphics
import Foundation

/// A Mac key combination, for example the shortcut that switches between Mac and PC.
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

	/// A shortcut must include Control or Option; otherwise it would interfere with typing.
	/// Command-only shortcuts are refused: they would take Command-C, Command-Q and the
	/// like away from every app, since the capture swallows the shortcut everywhere.
	public var isUsable: Bool { control || option }

	public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
		keyCode == self.keyCode
			&& flags.contains(.maskControl) == control
			&& flags.contains(.maskAlternate) == option
			&& flags.contains(.maskCommand) == command
			&& flags.contains(.maskShift) == shift
	}

	/// Name shown on screen with the Mac's modifier symbols, in Apple's order, for
	/// example "⌃⌘R". VoiceOver reads `spokenName` instead.
	public func displayName(characters: KeyTranslator.Characters?) -> String {
		var name = ""
		if control { name += "⌃" }
		if option { name += "⌥" }
		if shift { name += "⇧" }
		if command { name += "⌘" }
		let symbols: [UInt16: String] = [
			MacKeyCode.returnKey: "↩", MacKeyCode.tab: "⇥", MacKeyCode.delete: "⌫",
			MacKeyCode.escape: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
			123: "←", 124: "→", 125: "↓", 126: "↑",
		]
		return name + (symbols[keyCode] ?? Self.keyName(keyCode, characters: characters))
	}

	/// Name spelled out for speech and braille, for example "Control-Command-R":
	/// VoiceOver does not read the modifier symbols reliably.
	public func spokenName(characters: KeyTranslator.Characters?) -> String {
		var parts: [String] = []
		if control { parts.append(localized("Control")) }
		if option { parts.append(localized("Option")) }
		if shift { parts.append(localized("Shift")) }
		if command { parts.append(localized("Command")) }
		parts.append(Self.keyName(keyCode, characters: characters))
		return parts.joined(separator: "-")
	}

	private static func keyName(_ keyCode: UInt16, characters: KeyTranslator.Characters?) -> String {
		let names: [UInt16: String] = [
			MacKeyCode.returnKey: localized("Return"), MacKeyCode.tab: localized("Tab"),
			MacKeyCode.space: localized("Space"), MacKeyCode.delete: localized("Delete"),
			MacKeyCode.escape: localized("Escape"), 117: localized("Forward Delete"),
			115: localized("Home"), 119: localized("End"), 116: localized("Page Up"), 121: localized("Page Down"),
			123: localized("Left Arrow"), 124: localized("Right Arrow"),
			125: localized("Down Arrow"), 126: localized("Up Arrow"),
			122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
			98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
		]
		if let name = names[keyCode] {
			return name
		}
		if let plain = characters?.plain, !plain.isEmpty {
			return plain.uppercased()
		}
		return localized("key \(Int(keyCode))")
	}
}

/// A command triggered by a global shortcut, recognized whichever app is in the foreground.
public enum GlobalCommand: String, CaseIterable, Codable, Sendable {
	case toggleControl
	case pushClipboard

	public var label: String {
		switch self {
		case .toggleControl: localized("Switch between Mac and PC")
		case .pushClipboard: localized("Send clipboard to PC")
		}
	}

	/// Key codes 15 (R) and 8 (C): same position on AZERTY and QWERTY.
	public var defaultShortcut: KeyShortcut {
		switch self {
		case .toggleControl: KeyShortcut(keyCode: 15, control: true, command: true)
		case .pushClipboard: KeyShortcut(keyCode: 8, control: true, command: true)
		}
	}
}

/// Global keyboard capture through a `CGEventTap`, and forwarding of keys to the PC in remote mode.
///
/// Follows docs/keyboard-measurements.md: the tap sits at the HID level, otherwise VoiceOver
/// keeps its own commands; it is re-enabled if the system disables it; the fn key is
/// recognized by its key code, never by its flag, which the arrow keys also carry.
///
/// In local mode, only global shortcuts are intercepted. In remote mode, every key is
/// swallowed and sent to the PC, except key-ups for keys whose key-down was not sent:
/// those go back to the Mac, which saw the key-down.
@MainActor
public final class KeyboardCapture {
	public var shortcuts: [GlobalCommand: KeyShortcut] = Dictionary(
		uniqueKeysWithValues: GlobalCommand.allCases.map { ($0, $0.defaultShortcut) },
	)
	/// Turn off while recording a new shortcut, so that it reaches the window.
	public var areShortcutsEnabled = true
	public var translator = KeyTranslator()
	/// Called when the user types a global shortcut, in both local and remote mode.
	public var onCommand: ((GlobalCommand) -> Void)?
	/// Key to send to the PC, pressed or released.
	public var onKey: ((WindowsKey, Bool) -> Void)?

	public private(set) var isRemote = false
	public var isRunning: Bool { tap != nil }

	public let layout = MacKeyboardLayout()
	private var tap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?
	/// Keys sent to the PC as pressed, in the order they were pressed.
	private var sentDown: [WindowsKey] = []
	/// The PC key sent for each Mac key held down, so its release always sends the same
	/// key even if Shift, the layout or a setting changed meanwhile.
	private var heldKeys: [UInt16: WindowsKey] = [:]
	/// Whether fn is held, when it is the NVDA key (see `effectiveKeyCode`).
	private var isFunctionHeld = false
	/// Global shortcut keys whose key-down was swallowed: their key-up must be swallowed too.
	private var swallowedKeyUps: Set<UInt16> = []

	public init() {}

	// MARK: - Permissions

	/// Accessibility to swallow events, Input Monitoring to observe them.
	public static var hasPermissions: Bool {
		AXIsProcessTrusted() && CGPreflightListenEventAccess()
	}

	/// Triggers the system prompts. The user must then enable the app in
	/// System Settings; the result is not immediate.
	public static func requestPermissions() {
		// Value of `kAXTrustedCheckOptionPrompt`, which cannot be read without a warning in Swift 6.
		let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(options)
		_ = CGRequestListenEventAccess()
	}

	// MARK: - Lifecycle

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

	/// Switches to controlling the PC or back to the Mac. When switching back, every key
	/// still held down on the PC side is released there.
	public func setRemote(_ remote: Bool) {
		guard remote != isRemote else { return }
		if remote {
			layout.reload()
			sentDown.removeAll()
			heldKeys.removeAll()
			isFunctionHeld = false
		} else {
			releaseAll()
		}
		isRemote = remote
	}

	private func releaseAll() {
		guard !sentDown.isEmpty else { return }
		// Like NVDA: a neutral key first, so that releasing a lone modifier does not
		// trigger anything on the PC (Alt opening a menu, for example).
		onKey?(.none, true)
		onKey?(.none, false)
		for key in sentDown.reversed() {
			onKey?(key, false)
		}
		sentDown.removeAll()
		heldKeys.removeAll()
	}

	// MARK: - Events

	/// What we keep from a keyboard event: plain values, read on the spot.
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

	/// - Returns: `true` to swallow the event.
	func handle(_ event: KeyEvent) -> Bool {
		let keyCode = event.keyCode
		switch event.type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap {
				CGEvent.tapEnable(tap: tap, enable: true)
			}
			return false
		case .keyDown:
			let shortcutFlags = shortcutFlags(event.flags)
			if areShortcutsEnabled,
				let command = GlobalCommand.allCases.first(where: {
					shortcuts[$0]?.matches(keyCode: keyCode, flags: shortcutFlags) == true
				})
			{
				swallowedKeyUps.insert(keyCode)
				if !event.isRepeat {
					// The shortcut's modifiers already went to the PC: a neutral key first, as
					// NVDA does, so releasing them alone does nothing (Windows alone opens Start).
					if isRemote, !sentDown.isEmpty {
						onKey?(.none, true)
						onKey?(.none, false)
					}
					onCommand?(command)
				}
				return true
			}
			guard isRemote else { return false }
			if !press(keyCode, flags: event.flags) {
				// No PC equivalent: its release must not reach the Mac alone either.
				swallowedKeyUps.insert(keyCode)
			}
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
			if keyCode == MacKeyCode.function {
				isFunctionHeld = pressed
			}
			if pressed {
				press(keyCode, flags: event.flags)
				return true
			}
			return release(keyCode)
		default:
			return false
		}
	}

	/// Sends a key press. A held key repeats its key-down, as on Windows.
	/// - Returns: `false` when the key has no PC equivalent.
	@discardableResult
	private func press(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
		if let held = heldKeys[keyCode] {
			onKey?(held, true)
			return true
		}
		let effective = effectiveKeyCode(keyCode)
		guard let key = translator.translate(
			keyCode: effective,
			characters: layout.characters(for: effective),
			shift: flags.contains(.maskShift),
		) else { return false }
		heldKeys[keyCode] = key
		if !sentDown.contains(key) {
			sentDown.append(key)
		}
		onKey?(key, true)
		return true
	}

	private func release(_ keyCode: UInt16) -> Bool {
		guard let key = heldKeys.removeValue(forKey: keyCode) else { return false }
		// Another Mac key may still hold the same PC key: release it with the last one.
		if !heldKeys.values.contains(key) {
			sentDown.removeAll { $0 == key }
			onKey?(key, false)
		}
		return true
	}

	/// With fn as the NVDA key, macOS turns fn+arrows into Home, End, Page Up and Page Down,
	/// and fn+Delete into Forward Delete, before the tap sees them: turn them back, so
	/// NVDA+arrow reaches the PC as NVDA+arrow.
	private func effectiveKeyCode(_ keyCode: UInt16) -> UInt16 {
		guard translator.nvdaKey == .fn, isFunctionHeld else { return keyCode }
		let arrows: [UInt16: UInt16] = [116: 126, 121: 125, 115: 123, 119: 124, 117: MacKeyCode.delete]
		return arrows[keyCode] ?? keyCode
	}

	/// With Right Option as the NVDA key, its Option flag must not count for shortcuts,
	/// or NVDA+key combinations could fire an Option shortcut instead of reaching NVDA.
	private func shortcutFlags(_ flags: CGEventFlags) -> CGEventFlags {
		let leftOptionMask: UInt64 = 0x0020
		guard translator.nvdaKey == .rightOption, flags.rawValue & leftOptionMask == 0 else { return flags }
		return flags.subtracting(.maskAlternate)
	}

	/// State of a modifier after a `flagsChanged`, using the masks that distinguish left
	/// and right (`NX_DEVICE*KEYMASK`). `nil` for a key that is not a modifier.
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
			// Reliable here, since this is fn's own event.
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
			localized("The app does not have the Accessibility and Input Monitoring permissions yet.")
		case .tapCreationFailed:
			localized("Unable to capture the keyboard.")
		}
	}
}

/// The tap is installed on the main run loop, so this callback runs on the main thread.
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

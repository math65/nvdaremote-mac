import AppKit
import ApplicationServices
import Foundation
import Observation
import RemoteCore
import SwiftUI

/// A connection used before, offered again under Recent Connections.
struct RecentConnection: Codable, Hashable, Identifiable {
	var server: String
	var key: String

	var id: String { "\(server)\n\(key)" }
	var label: String { String(localized: "\(key) on \(server)") }
}

/// App state, and the driver of the session with the PC.
@MainActor
@Observable
final class AppModel {
	enum Phase {
		case idle
		case connecting
		case waitingForComputer
		case connected
	}

	static let publicServer = "nvdaremote.com"
	static let maximumRecents = 5

	private(set) var phase = Phase.idle
	/// The connection status shown in the window and the menu. Transient messages
	/// (clipboard, shortcut recording) are announced without replacing it.
	private(set) var status = String(localized: "Not connected.")
	/// The last input error, so the window can move focus to the faulty field.
	private(set) var inputError: ConnectionInfoError?
	private(set) var recents: [RecentConnection]

	/// The fields of the Connection window, kept here so that a connection started from
	/// the menu or a link shows in them too. An empty server means the public relay.
	var server: String {
		didSet { defaults.set(server, forKey: Keys.server) }
	}

	var key: String {
		didSet { defaults.set(key, forKey: Keys.key) }
	}

	var isActive: Bool { phase != .idle }
	var isComputerConnected: Bool { phase == .connected }

	/// True while the Mac keyboard drives the PC.
	private(set) var isControllingPC = false
	private(set) var hasKeyboardPermissions = KeyboardCapture.hasPermissions

	/// PC speech, beeps and sounds are silenced.
	var isMuted = false {
		didSet { session?.isMuted = isMuted }
	}

	// MARK: Settings

	var wordsPerMinute: Int {
		didSet {
			speech.wordsPerMinute = wordsPerMinute
			defaults.set(wordsPerMinute, forKey: Keys.wordsPerMinute)
		}
	}

	/// Same as NVDA's option: silence the PC when going back to work on the Mac.
	var mutesOnLocalControl: Bool {
		didSet { defaults.set(mutesOnLocalControl, forKey: Keys.mutesOnLocalControl) }
	}

	var playsRemoteSounds: Bool {
		didSet {
			session?.playsRemoteSounds = playsRemoteSounds
			defaults.set(playsRemoteSounds, forKey: Keys.playsRemoteSounds)
		}
	}

	/// The Mac's own sounds: connection, clipboard, switching.
	var playsAppSounds: Bool {
		didSet { defaults.set(playsAppSounds, forKey: Keys.playsAppSounds) }
	}

	/// Use the Mac's braille display for NVDA while controlling the PC.
	var showsBraille: Bool {
		didSet {
			defaults.set(showsBraille, forKey: Keys.showsBraille)
			if showsBraille, isControllingPC {
				takeBrailleDisplay()
			} else if !showsBraille {
				brailleDisplay?.release()
			}
			updateDeclaredBrailleCells()
		}
	}

	/// The braille display found on the Mac, shown for information in Settings.
	private(set) var brailleDisplayName: String?

	var nvdaKey: NVDAKeyChoice {
		didSet {
			capture.translator.nvdaKey = nvdaKey
			defaults.set(nvdaKey.rawValue, forKey: Keys.nvdaKey)
		}
	}

	var pcLayout: PCLayout {
		didSet {
			capture.translator.pcLayout = pcLayout
			defaults.set(pcLayout.rawValue, forKey: Keys.pcLayout)
		}
	}

	var shortcuts: [GlobalCommand: KeyShortcut] {
		didSet {
			capture.shortcuts = shortcuts
			defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Keys.shortcuts)
		}
	}

	/// While a new shortcut is being recorded, the current ones must not fire.
	var isRecordingShortcut = false {
		didSet { capture.areShortcutsEnabled = !isRecordingShortcut }
	}

	var showsInDock: Bool {
		didSet {
			defaults.set(showsInDock, forKey: Keys.showsInDock)
			if !showsInDock, !showsInMenuBar {
				showsInMenuBar = true
			}
			updateDockIcon()
			// Becoming an accessory app deactivates it: bring it back so the Settings
			// window stays under the user's fingers.
			NSApp?.activate()
		}
	}

	/// Also written by the system when the user removes the icon from the menu bar.
	var showsInMenuBar: Bool {
		didSet {
			defaults.set(showsInMenuBar, forKey: Keys.showsInMenuBar)
			// Without either icon the app could not be reached any more.
			if !showsInMenuBar, !showsInDock {
				showsInDock = true
			}
			updateDockIcon()
		}
	}

	/// The Dock icon follows the Connection window: closing it tucks the app away in the
	/// menu bar.
	@ObservationIgnored private var isConnectionWindowOpen = false

	@ObservationIgnored private let defaults = UserDefaults.standard
	@ObservationIgnored private let speech: SpeechOutput
	@ObservationIgnored private let tones = TonePlayer()
	@ObservationIgnored private let sounds = SoundPlayer()
	@ObservationIgnored private let trustStore = TrustStore()
	@ObservationIgnored private let capture = KeyboardCapture()
	@ObservationIgnored private let brailleMonitor = HIDBrailleDisplayMonitor()
	@ObservationIgnored private var session: LeaderSession?
	/// Whether the current session reached the server at least once, and whether its
	/// failure was already announced: retries every 5 seconds stay silent.
	@ObservationIgnored private var hasConnected = false
	@ObservationIgnored private var hasAnnouncedFailure = false
	@ObservationIgnored private var brailleDisplay: HIDBrailleDisplay?
	/// The display could not be taken (a brand driver holds it): the PC is told there is
	/// no braille, so it does not shrink its own line for nothing.
	@ObservationIgnored private var isBrailleUnavailable = false
	/// NVDA's last braille line, shown again when the display is taken.
	@ObservationIgnored private var brailleCells: [Int] = []
	@ObservationIgnored private var permissionTimer: Timer?
	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	enum Keys {
		static let server = "server"
		static let key = "lastConnection"
		static let wordsPerMinute = "wordsPerMinute"
		static let mutesOnLocalControl = "mutesOnLocalControl"
		static let playsRemoteSounds = "playsRemoteSounds"
		static let playsAppSounds = "playsAppSounds"
		static let nvdaKey = "nvdaKey"
		static let pcLayout = "pcLayout"
		static let shortcuts = "shortcuts"
		static let recents = "recentConnections"
		static let showsInDock = "showsInDock"
		static let showsInMenuBar = "showsInMenuBar"
		static let showsBraille = "showsBraille"
		static let hasAskedForPermissions = "hasAskedForPermissions"
	}

	init() {
		let defaults = UserDefaults.standard
		defaults.register(defaults: [
			Keys.playsRemoteSounds: true,
			Keys.playsAppSounds: true,
			Keys.showsInDock: true,
			Keys.showsInMenuBar: true,
		])
		server = defaults.string(forKey: Keys.server) ?? ""
		key = defaults.string(forKey: Keys.key) ?? ""
		let savedRate = defaults.integer(forKey: Keys.wordsPerMinute)
		let rate = savedRate > 0 ? savedRate : 300
		wordsPerMinute = rate
		mutesOnLocalControl = defaults.bool(forKey: Keys.mutesOnLocalControl)
		playsRemoteSounds = defaults.bool(forKey: Keys.playsRemoteSounds)
		playsAppSounds = defaults.bool(forKey: Keys.playsAppSounds)
		let dock = defaults.bool(forKey: Keys.showsInDock)
		showsInMenuBar = defaults.bool(forKey: Keys.showsInMenuBar)
		showsInDock = dock || !defaults.bool(forKey: Keys.showsInMenuBar)
		showsBraille = defaults.bool(forKey: Keys.showsBraille)
		nvdaKey = defaults.string(forKey: Keys.nvdaKey).flatMap(NVDAKeyChoice.init(rawValue:)) ?? .capsLock
		// The PC usually shares the user's language: French AZERTY for French speakers.
		pcLayout = defaults.string(forKey: Keys.pcLayout).flatMap(PCLayout.init(rawValue:))
			?? (Locale.current.language.languageCode == .french ? .french : .us)
		var shortcuts = Dictionary(uniqueKeysWithValues: GlobalCommand.allCases.map { ($0, $0.defaultShortcut) })
		if let data = defaults.data(forKey: Keys.shortcuts),
			let saved = try? JSONDecoder().decode([GlobalCommand: KeyShortcut].self, from: data)
		{
			shortcuts.merge(saved) { _, saved in saved }
		}
		self.shortcuts = shortcuts
		recents = defaults.data(forKey: Keys.recents)
			.flatMap { try? JSONDecoder().decode([RecentConnection].self, from: $0) } ?? []
		speech = SpeechOutput(wordsPerMinute: rate)

		capture.translator = KeyTranslator(nvdaKey: nvdaKey, pcLayout: pcLayout)
		capture.shortcuts = shortcuts
		capture.onCommand = { [weak self] command in self?.perform(command) }
		capture.onKey = { [weak self] key, pressed in self?.session?.sendKey(key, pressed: pressed) }
		brailleMonitor.onChange = { [weak self] in self?.brailleDisplaysChanged() }
		findBrailleDisplay()

		// After a crash while controlling the PC, Caps Lock would still be remapped.
		try? CapsLockRemap.remove()
		refreshKeyboardPermissions()
		// First launch: ask right away, otherwise the global shortcut would silently do
		// nothing, since it cannot be captured without the permissions.
		if !hasKeyboardPermissions, !defaults.bool(forKey: Keys.hasAskedForPermissions) {
			defaults.set(true, forKey: Keys.hasAskedForPermissions)
			DispatchQueue.main.async { [weak self] in self?.requestKeyboardPermissions() }
		}

		let center = NotificationCenter.default
		observers.append(center.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.shutdown() }
		})
		// The window that sends this is still visible: look once it is gone.
		observers.append(center.addObserver(
			forName: NSWindow.willCloseNotification, object: nil, queue: .main,
		) { [weak self] _ in
			DispatchQueue.main.async {
				MainActor.assumeIsolated { self?.windowsDidChange() }
			}
		})
		observers.append(center.addObserver(
			forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshKeyboardPermissions() }
		})
	}

	// MARK: - Dock and menu bar

	func connectionWindowDidOpen() {
		isConnectionWindowOpen = true
		updateDockIcon()
	}

	/// Closing the window (Command-W) hides the app into the menu bar and gives focus
	/// back to the previous app, once no other window, such as Settings, is open.
	/// Without a menu bar icon, the app stays in the Dock, or it could not be reached.
	func connectionWindowDidClose() {
		isConnectionWindowOpen = false
		windowsDidChange()
	}

	/// Called when any window closes. Leaving the Dock deactivates the app, and macOS
	/// then refuses to give it the focus back: so the Dock icon stays while a window
	/// is open, and the app only tucks itself away with the last one.
	func windowsDidChange() {
		updateDockIcon()
		if !hasOpenWindow, showsInMenuBar {
			NSApp?.hide(nil)
		}
	}

	private var hasOpenWindow: Bool {
		NSApp?.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) } ?? false
	}

	private func updateDockIcon() {
		let visible = showsInDock && (isConnectionWindowOpen || hasOpenWindow || !showsInMenuBar)
		NSApp?.setActivationPolicy(visible ? .regular : .accessory)
	}

	// MARK: - Connection

	/// Connects with the typed server and key. An `nvdaremote://` link pasted in the
	/// key field wins over the typed server. An empty server means the public relay.
	@discardableResult
	func connect() -> Bool {
		let keyOrLink = key.trimmingCharacters(in: .whitespacesAndNewlines)
		inputError = nil
		do {
			let info = keyOrLink.lowercased().hasPrefix("nvdaremote:")
				? try ConnectionInfo(url: keyOrLink)
				: try ConnectionInfo(
					server: server.trimmingCharacters(in: .whitespaces).isEmpty ? Self.publicServer : server,
					key: keyOrLink,
				)
			start(info)
			return true
		} catch {
			inputError = error
			announce(error.localizedDescription)
			return false
		}
	}

	func connect(to recent: RecentConnection) {
		server = recent.server
		key = recent.key
		connect()
	}

	/// A clicked `nvdaremote://` link. Replacing a running session needs the user's
	/// consent: the link may come from anywhere, and keys typed afterwards would go to
	/// that other computer.
	func open(_ url: URL) {
		NSApp.activate()
		let info: ConnectionInfo
		do {
			info = try ConnectionInfo(url: url.absoluteString)
		} catch {
			announce(error.localizedDescription)
			return
		}
		if isActive {
			let alert = NSAlert()
			alert.messageText = String(localized: "Connect to \(info.key) on \(info.serverDescription)?")
			alert.informativeText = String(localized: "The current connection will be closed.")
			alert.addButton(withTitle: String(localized: "Connect"))
			alert.addButton(withTitle: String(localized: "Cancel"))
			guard alert.runModal() == .alertFirstButtonReturn else { return }
		}
		server = info.serverDescription
		key = info.key
		start(info)
	}

	func disconnect() {
		switchToMac(announcing: false)
		clearBraille()
		session?.stop()
		session = nil
		isMuted = false
		phase = .idle
		play(.disconnected)
		report(String(localized: "Disconnected."))
	}

	func forgetRecents() {
		recents = []
		defaults.removeObject(forKey: Keys.recents)
	}

	private func start(_ info: ConnectionInfo) {
		// A new connection must first give the keyboard back.
		switchToMac(announcing: false)
		session?.stop()
		let session = LeaderSession(
			info: info,
			trustedFingerprint: trustStore.fingerprint(for: info.address),
			speech: speech,
			tones: tones,
			sounds: sounds,
		)
		session.playsRemoteSounds = playsRemoteSounds
		findBrailleDisplay()
		session.brailleCellCount = declaredBrailleCells
		session.onEvent = { [weak self] event in self?.handle(event, info: info) }
		self.session = session
		hasConnected = false
		hasAnnouncedFailure = false
		isMuted = false
		session.start()
	}

	private func handle(_ event: LeaderSession.Event, info: ConnectionInfo) {
		switch event {
		case .connecting:
			phase = .connecting
			report(String(localized: "Connecting to \(info.serverDescription)…"), important: false)
		case .connected:
			phase = .connecting
			hasConnected = true
			hasAnnouncedFailure = false
		case let .joined(followers):
			remember(info)
			phase = followers == 0 ? .waitingForComputer : .connected
			play(followers == 0 ? .connected : .controlling)
			report(followers == 0
				? String(localized: "Connected. Waiting for the PC.")
				: String(localized: "Connected to the PC."))
		case .followerJoined:
			phase = .connected
			play(.controlling)
			report(String(localized: "PC connected."))
		case .followerLeft:
			guard session?.followerCount ?? 0 == 0 else { return }
			phase = .waitingForComputer
			switchToMac(announcing: false)
			play(.disconnected)
			report(String(localized: "PC disconnected. Waiting for it to come back."))
		case let .disconnected(reason, willRetry):
			guard willRetry else {
				endSession()
				report(String(localized: "Connection lost: \(reason)."))
				return
			}
			phase = .connecting
			switchToMac(announcing: false)
			let text = hasConnected
				? String(localized: "Connection lost: \(reason). Retrying in 5 seconds.")
				: String(localized: "Unable to connect: \(reason). Retrying in 5 seconds.")
			// Only the first failure is heard; retries update the status silently.
			if hasAnnouncedFailure {
				status = text
			} else {
				hasAnnouncedFailure = true
				play(.disconnected)
				report(text)
			}
		case let .message(text):
			announce(text)
		case let .braille(cells):
			brailleCells = cells
			brailleDisplay?.show(cells)
		case let .clipboardReceived(text):
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
			play(.clipboardReceive)
			announce(String(localized: "Clipboard received."))
		case let .ended(reason):
			endSession()
			play(.error)
			report(String(localized: "Stopped: \(reason)."))
		case let .untrustedCertificate(fingerprint):
			endSession()
			play(.error)
			report(String(localized: "Certificate to verify."))
			askToTrust(info: info, fingerprint: fingerprint)
		}
	}

	private func endSession() {
		switchToMac(announcing: false)
		clearBraille()
		session?.stop()
		session = nil
		isMuted = false
		phase = .idle
	}

	/// A PC that hosts the connection itself presents its own certificate. The dialog
	/// shows whether or not the Connection window is open.
	private func askToTrust(info: ConnectionInfo, fingerprint: String) {
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = String(localized: "Unknown Certificate")
		alert.informativeText = String(localized: """
			The PC hosts the connection itself and presents its own certificate. \
			Only trust it if you are expecting this PC.

			Fingerprint: \(Self.grouped(fingerprint))
			""")
		alert.addButton(withTitle: String(localized: "Trust and Connect"))
		alert.addButton(withTitle: String(localized: "Cancel"))
		guard alert.runModal() == .alertFirstButtonReturn else {
			report(String(localized: "Not connected."), important: false)
			return
		}
		do {
			try trustStore.trust(fingerprint, for: info.address)
		} catch {
			report(String(localized: "Unable to save the certificate: \(error.localizedDescription)"))
			return
		}
		start(info)
	}

	/// A fingerprint in groups of four, easier to compare by ear or in braille.
	static func grouped(_ fingerprint: String) -> String {
		stride(from: 0, to: fingerprint.count, by: 4).map { start in
			let from = fingerprint.index(fingerprint.startIndex, offsetBy: start)
			let to = fingerprint.index(from, offsetBy: 4, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
			return String(fingerprint[from..<to])
		}.joined(separator: " ")
	}

	private func remember(_ info: ConnectionInfo) {
		let recent = RecentConnection(server: info.serverDescription, key: info.key)
		recents.removeAll { $0 == recent }
		recents.insert(recent, at: 0)
		recents = Array(recents.prefix(Self.maximumRecents))
		defaults.set(try? JSONEncoder().encode(recents), forKey: Keys.recents)
	}

	// MARK: - Commands

	func perform(_ command: GlobalCommand) {
		switch command {
		case .toggleControl: toggleComputerControl()
		case .pushClipboard: pushClipboard()
		}
	}

	func shortcutName(for command: GlobalCommand) -> String {
		guard let shortcut = shortcuts[command] else { return "" }
		return shortcut.displayName(characters: capture.layout.characters(for: shortcut.keyCode))
	}

	/// The shortcut as a menu key equivalent, so menus show it the Mac way (⌃⌘R) and
	/// VoiceOver reads it natively. Pressing it never reaches the menu while the keyboard
	/// capture runs: the capture swallows global shortcuts first.
	func menuShortcut(for command: GlobalCommand) -> KeyboardShortcut? {
		guard let shortcut = shortcuts[command] else { return nil }
		let special: [UInt16: KeyEquivalent] = [
			MacKeyCode.returnKey: .return, MacKeyCode.tab: .tab, MacKeyCode.space: .space,
			MacKeyCode.delete: .delete, MacKeyCode.escape: .escape, 117: .deleteForward,
			115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
			123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
		]
		let key: KeyEquivalent
		if let equivalent = special[shortcut.keyCode] {
			key = equivalent
		} else if let character = capture.layout.characters(for: shortcut.keyCode)?.plain.first {
			key = KeyEquivalent(character)
		} else {
			return nil
		}
		var modifiers: EventModifiers = []
		if shortcut.control { modifiers.insert(.control) }
		if shortcut.option { modifiers.insert(.option) }
		if shortcut.shift { modifiers.insert(.shift) }
		if shortcut.command { modifiers.insert(.command) }
		return KeyboardShortcut(key, modifiers: modifiers)
	}

	/// The shortcut spelled out, for speech and braille.
	func spokenShortcutName(for command: GlobalCommand) -> String {
		guard let shortcut = shortcuts[command] else { return "" }
		return shortcut.spokenName(characters: capture.layout.characters(for: shortcut.keyCode))
	}

	func pushClipboard() {
		guard let session, isComputerConnected else {
			announce(String(localized: "No PC connected."))
			return
		}
		guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
			announce(String(localized: "The clipboard contains no text."))
			return
		}
		session.pushClipboard(text)
		play(.clipboardPush)
		announce(String(localized: "Clipboard sent."))
	}

	// MARK: - Keyboard

	/// Shows macOS's permission requests, and opens the System Settings pane of the first
	/// missing permission, where the user switches NVDA Remote on.
	func requestKeyboardPermissions() {
		KeyboardCapture.requestPermissions()
		refreshKeyboardPermissions()
		guard !hasKeyboardPermissions else { return }
		let pane = AXIsProcessTrusted() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
			NSWorkspace.shared.open(url)
		}
	}

	/// Starts the capture once the permissions are there. They are granted in System
	/// Settings, possibly while the app stays in the background: check every few
	/// seconds until then.
	func refreshKeyboardPermissions() {
		hasKeyboardPermissions = KeyboardCapture.hasPermissions
		startCapture()
		if hasKeyboardPermissions {
			permissionTimer?.invalidate()
			permissionTimer = nil
		} else if permissionTimer == nil {
			permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated { self?.refreshKeyboardPermissions() }
			}
		}
	}

	/// Capture runs for the whole life of the app, so the global shortcuts work
	/// whatever app is in front.
	private func startCapture() {
		guard !capture.isRunning, hasKeyboardPermissions else { return }
		do {
			try capture.start()
		} catch {
			announce(error.localizedDescription)
		}
	}

	func toggleComputerControl() {
		if isControllingPC {
			switchToMac(announcing: true)
		} else {
			switchToPC()
		}
	}

	private func switchToPC() {
		guard isComputerConnected else {
			announce(String(localized: "No PC connected."))
			return
		}
		guard capture.isRunning else {
			announce(String(localized: "To control the PC, allow NVDA Remote in System Settings, under Accessibility and Input Monitoring."))
			requestKeyboardPermissions()
			return
		}
		if nvdaKey == .capsLock {
			do {
				try CapsLockRemap.apply()
			} catch {
				announce(error.localizedDescription)
				return
			}
		}
		// A shortcut being recorded would otherwise keep the global shortcuts off,
		// leaving no keyboard way back to the Mac.
		isRecordingShortcut = false
		capture.setRemote(true)
		isControllingPC = true
		isMuted = false
		if showsBraille {
			takeBrailleDisplay()
		}
		if playsAppSounds {
			tones.beep(hz: 880, milliseconds: 60, left: 50, right: 50)
		}
		report(String(localized: "Controlling the PC."))
	}

	private func switchToMac(announcing: Bool) {
		guard isControllingPC else { return }
		capture.setRemote(false)
		isControllingPC = false
		brailleDisplay?.release()
		do {
			try CapsLockRemap.remove()
		} catch {
			announce(String(localized: "Caps Lock could not be restored: \(error.localizedDescription) Restarting the Mac will restore it."))
		}
		// "Controlling the PC." no longer describes the connection.
		if isComputerConnected {
			status = String(localized: "Connected to the PC.")
		}
		guard announcing else { return }
		if mutesOnLocalControl {
			isMuted = true
		}
		if playsAppSounds {
			tones.beep(hz: 440, milliseconds: 60, left: 50, right: 50)
		}
		announce(mutesOnLocalControl
			? String(localized: "Controlling the Mac. PC muted.")
			: String(localized: "Controlling the Mac."))
	}

	private func shutdown() {
		switchToMac(announcing: false)
		brailleDisplay?.release()
		capture.stop()
		session?.stop()
	}

	// MARK: - Braille

	/// Looks for a HID braille display; its width is what the PC is told.
	func findBrailleDisplay() {
		guard brailleDisplay?.isAcquired != true else { return }
		let display = HIDBrailleDisplay.connected()
		display?.onGesture = { [weak self] gesture in self?.session?.sendBraille(gesture) }
		display?.onRemoval = { [weak self] in self?.brailleDisplayRemoved() }
		brailleDisplay = display
		brailleDisplayName = display?.name
		isBrailleUnavailable = false
		updateDeclaredBrailleCells()
	}

	/// "Look Again" in Settings: says what was found.
	func lookForBrailleDisplay() {
		findBrailleDisplay()
		announce(brailleDisplayName.map { String(localized: "Braille display: \($0)") }
			?? String(localized: "No braille display found."))
	}

	private var declaredBrailleCells: Int {
		showsBraille && !isBrailleUnavailable ? brailleDisplay?.cellCount ?? 0 : 0
	}

	private func updateDeclaredBrailleCells() {
		session?.brailleCellCount = declaredBrailleCells
	}

	/// Takes the display from VoiceOver for the time of PC control. VoiceOver keeps
	/// running and gets it back when control returns to the Mac, or if the app quits.
	private func takeBrailleDisplay() {
		findBrailleDisplay()
		guard let brailleDisplay else { return }
		do {
			try brailleDisplay.acquire()
			brailleDisplay.show(brailleCells)
		} catch {
			isBrailleUnavailable = true
			updateDeclaredBrailleCells()
			announce(error.localizedDescription)
		}
	}

	private func brailleDisplayRemoved() {
		brailleDisplay = nil
		brailleDisplayName = nil
		updateDeclaredBrailleCells()
		if isControllingPC, showsBraille {
			announce(String(localized: "Braille display disconnected."))
		}
	}

	/// A display appeared or disappeared (Bluetooth reconnect, cable, wake from sleep).
	/// While the PC is controlled, a display that comes back is taken again, once
	/// VoiceOver has loaded it: taking it first could keep VoiceOver from getting it back.
	private func brailleDisplaysChanged() {
		guard brailleDisplay?.isAcquired != true else { return }
		findBrailleDisplay()
		guard isControllingPC, showsBraille, brailleDisplay != nil else { return }
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(2))
			guard let self, self.isControllingPC, self.showsBraille, self.brailleDisplay?.isAcquired != true else { return }
			self.takeBrailleDisplay()
		}
	}

	private func clearBraille() {
		brailleCells = []
		brailleDisplay?.show([])
	}

	// MARK: - Announcements and sounds

	private func play(_ cue: SoundPlayer.Cue) {
		if playsAppSounds {
			sounds.play(cue)
		}
	}

	/// Sets the connection status and makes it heard.
	private func report(_ text: String, important: Bool = true) {
		status = text
		announce(text, important: important)
	}

	/// Makes a message heard without changing the status.
	///
	/// VoiceOver only announces what the frontmost app says. When the app is in the
	/// background, its own voice speaks important messages instead.
	func announce(_ text: String, important: Bool = true) {
		if NSApp?.isActive == true {
			var announcement = AttributedString(text)
			announcement.accessibilitySpeechAnnouncementPriority = .high
			AccessibilityNotification.Announcement(announcement).post()
		} else if important {
			speech.speak([.text(text)], priority: .now)
		}
	}
}

import AppKit
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

	/// A self-signed certificate waiting for the user's decision.
	struct PendingTrust: Identifiable {
		let id = UUID()
		let info: ConnectionInfo
		let fingerprint: String
	}

	static let publicServer = "nvdaremote.com"
	static let maximumRecents = 5

	private(set) var phase = Phase.idle
	private(set) var status = String(localized: "Not connected.")
	var pendingTrust: PendingTrust?
	/// The last input error, so the window can move focus to the faulty field.
	private(set) var inputError: ConnectionInfoError?
	private(set) var recents: [RecentConnection]

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
			if !showsBraille {
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
			updateDockIcon()
			// Becoming an accessory app deactivates it: bring it back so the Settings
			// window stays under the user's fingers.
			NSApp?.activate()
		}
	}

	var showsInMenuBar: Bool {
		didSet {
			defaults.set(showsInMenuBar, forKey: Keys.showsInMenuBar)
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
	@ObservationIgnored private var session: LeaderSession?
	@ObservationIgnored private var brailleDisplay: HIDBrailleDisplay?
	/// NVDA's last braille line, shown again when the display is taken.
	@ObservationIgnored private var brailleCells: [Int] = []
	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	enum Keys {
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
	}

	init() {
		let defaults = UserDefaults.standard
		defaults.register(defaults: [
			Keys.playsRemoteSounds: true,
			Keys.playsAppSounds: true,
			Keys.showsInDock: true,
			Keys.showsInMenuBar: true,
		])
		let savedRate = defaults.integer(forKey: Keys.wordsPerMinute)
		let rate = savedRate > 0 ? savedRate : 300
		wordsPerMinute = rate
		mutesOnLocalControl = defaults.bool(forKey: Keys.mutesOnLocalControl)
		playsRemoteSounds = defaults.bool(forKey: Keys.playsRemoteSounds)
		playsAppSounds = defaults.bool(forKey: Keys.playsAppSounds)
		showsInDock = defaults.bool(forKey: Keys.showsInDock)
		showsInMenuBar = defaults.bool(forKey: Keys.showsInMenuBar)
		showsBraille = defaults.bool(forKey: Keys.showsBraille)
		nvdaKey = defaults.string(forKey: Keys.nvdaKey).flatMap(NVDAKeyChoice.init(rawValue:)) ?? .capsLock
		pcLayout = defaults.string(forKey: Keys.pcLayout).flatMap(PCLayout.init(rawValue:)) ?? .french
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
		findBrailleDisplay()

		// After a crash while controlling the PC, Caps Lock would still be remapped.
		try? CapsLockRemap.remove()
		startCapture()

		let center = NotificationCenter.default
		observers.append(center.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.shutdown() }
		})
		// Permissions are granted in System Settings: check again when the app comes back.
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
	/// back to the previous app. Without a menu bar icon, the app stays in the Dock,
	/// or it could not be reached any more.
	func connectionWindowDidClose() {
		isConnectionWindowOpen = false
		updateDockIcon()
		if showsInMenuBar {
			NSApp?.hide(nil)
		}
	}

	private func updateDockIcon() {
		let visible = showsInDock && (isConnectionWindowOpen || !showsInMenuBar)
		NSApp?.setActivationPolicy(visible ? .regular : .accessory)
	}

	// MARK: - Connection

	/// Connects with the typed server and key. An `nvdaremote://` link pasted in the
	/// key field wins over the typed server. An empty server means the public relay,
	/// which the field shows as its placeholder.
	/// - Returns: the connection used, so the window can show a pasted link split into
	///   server and key; `nil` when the input is invalid.
	@discardableResult
	func connect(server: String, keyOrLink: String) -> ConnectionInfo? {
		let keyOrLink = keyOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
		inputError = nil
		do {
			let info = keyOrLink.lowercased().hasPrefix("nvdaremote:")
				? try ConnectionInfo(url: keyOrLink)
				: try ConnectionInfo(
					server: server.trimmingCharacters(in: .whitespaces).isEmpty ? Self.publicServer : server,
					key: keyOrLink,
				)
			start(info)
			return info
		} catch {
			inputError = error
			announce(error.localizedDescription)
			return nil
		}
	}

	func connect(to recent: RecentConnection) {
		connect(server: recent.server, keyOrLink: recent.key)
	}

	func disconnect() {
		switchToMac(announcing: false)
		clearBraille()
		session?.stop()
		session = nil
		isMuted = false
		phase = .idle
		play(.disconnected)
		announce(String(localized: "Disconnected."))
	}

	func trust(_ pending: PendingTrust) {
		pendingTrust = nil
		do {
			try trustStore.trust(pending.fingerprint, for: pending.info.address)
		} catch {
			announce(String(localized: "Unable to save the certificate: \(error.localizedDescription)"))
			return
		}
		start(pending.info)
	}

	func forgetRecents() {
		recents = []
		defaults.removeObject(forKey: Keys.recents)
	}

	private func start(_ info: ConnectionInfo) {
		// A new connection, for example from a link, must first give the keyboard back.
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
		isMuted = false
		session.start()
	}

	private func handle(_ event: LeaderSession.Event, info: ConnectionInfo) {
		switch event {
		case .connecting:
			phase = .connecting
			announce(String(localized: "Connecting to \(info.serverDescription)…"), important: false)
		case .connected:
			phase = .connecting
		case let .joined(followers):
			remember(info)
			phase = followers == 0 ? .waitingForComputer : .connected
			play(followers == 0 ? .connected : .controlling)
			announce(followers == 0
				? String(localized: "Connected. Waiting for the PC.")
				: String(localized: "Connected to the PC."))
		case .followerJoined:
			phase = .connected
			play(.controlling)
			announce(String(localized: "PC connected."))
		case .followerLeft:
			guard session?.followerCount ?? 0 == 0 else { return }
			phase = .waitingForComputer
			switchToMac(announcing: false)
			play(.disconnected)
			announce(String(localized: "PC disconnected. Waiting for it to come back."))
		case let .disconnected(reason, willRetry):
			phase = willRetry ? .connecting : .idle
			switchToMac(announcing: false)
			play(.disconnected)
			announce(willRetry
				? String(localized: "Connection lost: \(reason). Retrying in 5 seconds.")
				: String(localized: "Connection lost: \(reason)."))
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
			announce(String(localized: "Stopped: \(reason)."))
		case let .untrustedCertificate(fingerprint):
			endSession()
			status = String(localized: "Certificate to verify.")
			pendingTrust = PendingTrust(info: info, fingerprint: fingerprint)
		}
	}

	private func endSession() {
		switchToMac(announcing: false)
		clearBraille()
		session = nil
		isMuted = false
		phase = .idle
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

	/// The shortcut spelled out, for speech, braille and menu titles.
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

	func requestKeyboardPermissions() {
		KeyboardCapture.requestPermissions()
		refreshKeyboardPermissions()
	}

	func refreshKeyboardPermissions() {
		hasKeyboardPermissions = KeyboardCapture.hasPermissions
		startCapture()
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
			announce(String(localized: "The keyboard cannot be captured: grant the permissions in Settings first."))
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
		capture.setRemote(true)
		isControllingPC = true
		isMuted = false
		if showsBraille {
			takeBrailleDisplay()
		}
		if playsAppSounds {
			tones.beep(hz: 880, milliseconds: 60, left: 50, right: 50)
		}
		announce(String(localized: "Controlling the PC."))
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
			return
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
		brailleDisplay = display
		brailleDisplayName = display?.name
		updateDeclaredBrailleCells()
	}

	private var declaredBrailleCells: Int {
		showsBraille ? brailleDisplay?.cellCount ?? 0 : 0
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
			announce(error.localizedDescription)
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

	/// Updates the displayed status and makes it heard.
	///
	/// VoiceOver only announces what the frontmost app says. When the user works in
	/// another app, or drives the PC, the app's own voice speaks important messages.
	func announce(_ text: String, important: Bool = true) {
		status = text
		if NSApp?.isActive == true {
			var announcement = AttributedString(text)
			announcement.accessibilitySpeechAnnouncementPriority = .high
			AccessibilityNotification.Announcement(announcement).post()
		} else if important {
			speech.speak([.text(text)], priority: .now)
		}
	}
}

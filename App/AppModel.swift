import AppKit
import Foundation
import Observation
import RemoteCore
import SwiftUI

/// État de l'application et pilotage de la session avec le PC.
@MainActor
@Observable
final class AppModel {
	enum Phase {
		case idle
		case connecting
		case waitingForComputer
		case connected
	}

	/// Certificat auto-signé en attente d'une décision de l'utilisateur.
	struct PendingTrust: Identifiable {
		let id = UUID()
		let info: ConnectionInfo
		let fingerprint: String
	}

	static let publicServer = "nvdaremote.com"

	private(set) var phase = Phase.idle
	private(set) var status = "Non connecté."
	var pendingTrust: PendingTrust?

	var isActive: Bool { phase != .idle }

	// MARK: Réglages

	var wordsPerMinute: Int {
		didSet {
			speech.wordsPerMinute = wordsPerMinute
			UserDefaults.standard.set(wordsPerMinute, forKey: Keys.wordsPerMinute)
		}
	}

	var nvdaKey: NVDAKeyChoice {
		didSet {
			capture.translator.nvdaKey = nvdaKey
			UserDefaults.standard.set(nvdaKey.rawValue, forKey: Keys.nvdaKey)
		}
	}

	var pcLayout: PCLayout {
		didSet {
			capture.translator.pcLayout = pcLayout
			UserDefaults.standard.set(pcLayout.rawValue, forKey: Keys.pcLayout)
		}
	}

	var toggleShortcut: KeyShortcut {
		didSet {
			capture.toggleShortcut = toggleShortcut
			UserDefaults.standard.set(try? JSONEncoder().encode(toggleShortcut), forKey: Keys.toggleShortcut)
		}
	}

	/// Pendant l'enregistrement d'un nouveau raccourci, l'ancien ne doit plus basculer.
	var isRecordingShortcut = false {
		didSet { capture.isToggleEnabled = !isRecordingShortcut }
	}

	// MARK: Clavier

	/// Vrai quand le clavier du Mac pilote le PC.
	private(set) var isControllingPC = false
	private(set) var hasKeyboardPermissions = KeyboardCapture.hasPermissions

	var toggleShortcutName: String {
		toggleShortcut.displayName(characters: capture.layout.characters(for: toggleShortcut.keyCode))
	}

	@ObservationIgnored private let speech: SpeechOutput
	@ObservationIgnored private let tones = TonePlayer()
	@ObservationIgnored private let trustStore = TrustStore()
	@ObservationIgnored private let capture = KeyboardCapture()
	@ObservationIgnored private var session: LeaderSession?
	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	private enum Keys {
		static let wordsPerMinute = "wordsPerMinute"
		static let nvdaKey = "nvdaKey"
		static let pcLayout = "pcLayout"
		static let toggleShortcut = "toggleShortcut"
	}

	init() {
		let defaults = UserDefaults.standard
		let savedRate = defaults.integer(forKey: Keys.wordsPerMinute)
		let rate = savedRate > 0 ? savedRate : 300
		wordsPerMinute = rate
		nvdaKey = defaults.string(forKey: Keys.nvdaKey).flatMap(NVDAKeyChoice.init(rawValue:)) ?? .capsLock
		pcLayout = defaults.string(forKey: Keys.pcLayout).flatMap(PCLayout.init(rawValue:)) ?? .french
		toggleShortcut = defaults.data(forKey: Keys.toggleShortcut)
			.flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) } ?? .defaultToggle
		speech = SpeechOutput(wordsPerMinute: rate)

		capture.translator = KeyTranslator(nvdaKey: nvdaKey, pcLayout: pcLayout)
		capture.toggleShortcut = toggleShortcut
		capture.onToggle = { [weak self] in self?.toggleComputerControl() }
		capture.onKey = { [weak self] key, pressed in self?.session?.sendKey(key, pressed: pressed) }

		// Après un arrêt brutal pendant le contrôle du PC, Verr. maj. serait restée remappée.
		try? CapsLockRemap.remove()

		let center = NotificationCenter.default
		observers.append(center.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.shutdown() }
		})
		// Les autorisations s'accordent dans Réglages Système : on revérifie au retour dans l'app.
		observers.append(center.addObserver(
			forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshKeyboardPermissions() }
		})
	}

	// MARK: - Connexion

	/// Se connecte avec le serveur et la clé saisis. Un lien `nvdaremote://` collé
	/// dans le champ de clé l'emporte sur le serveur saisi. Un serveur vide désigne
	/// le relais public, que le champ affiche en indication.
	/// - Returns: la connexion retenue, pour que la fenêtre puisse réafficher le lien éclaté
	///   en serveur et clé ; `nil` si la saisie est invalide.
	@discardableResult
	func connect(server: String, keyOrLink: String) -> ConnectionInfo? {
		let keyOrLink = keyOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
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
			announce(error.localizedDescription)
			return nil
		}
	}

	func disconnect() {
		switchToMac(announcing: false)
		capture.stop()
		session?.stop()
		session = nil
		phase = .idle
		announce("Déconnecté.")
	}

	func trust(_ pending: PendingTrust) {
		pendingTrust = nil
		do {
			try trustStore.trust(pending.fingerprint, for: pending.info.address)
		} catch {
			announce("Impossible d'enregistrer le certificat : \(error.localizedDescription)")
			return
		}
		start(pending.info)
	}

	private func start(_ info: ConnectionInfo) {
		session?.stop()
		let session = LeaderSession(
			info: info,
			trustedFingerprint: trustStore.fingerprint(for: info.address),
			speech: speech,
			tones: tones,
		)
		session.onEvent = { [weak self] event in self?.handle(event, info: info) }
		self.session = session
		session.start()
		startCapture()
	}

	private func handle(_ event: LeaderSession.Event, info: ConnectionInfo) {
		switch event {
		case .connecting:
			phase = .connecting
			announce("Connexion à \(info.serverDescription)…")
		case .connected:
			phase = .connecting
		case let .joined(followers):
			phase = followers == 0 ? .waitingForComputer : .connected
			announce(followers == 0 ? "Connecté. En attente du PC." : "Connecté au PC.")
		case .followerJoined:
			phase = .connected
			announce("PC connecté.")
		case .followerLeft:
			guard session?.followerCount ?? 0 == 0 else { return }
			phase = .waitingForComputer
			switchToMac(announcing: false)
			announce("PC déconnecté. En attente de son retour.")
		case let .disconnected(reason, willRetry):
			phase = willRetry ? .connecting : .idle
			switchToMac(announcing: false)
			announce("Connexion perdue : \(reason).\(willRetry ? " Nouvel essai dans 5 secondes." : "")")
		case let .message(text):
			announce(text)
		case let .ended(reason):
			endSession()
			announce("Arrêt : \(reason).")
		case let .untrustedCertificate(fingerprint):
			endSession()
			status = "Certificat à vérifier."
			pendingTrust = PendingTrust(info: info, fingerprint: fingerprint)
		}
	}

	private func endSession() {
		switchToMac(announcing: false)
		capture.stop()
		session = nil
		phase = .idle
	}

	// MARK: - Clavier

	func requestKeyboardPermissions() {
		KeyboardCapture.requestPermissions()
		refreshKeyboardPermissions()
	}

	func refreshKeyboardPermissions() {
		hasKeyboardPermissions = KeyboardCapture.hasPermissions
		if hasKeyboardPermissions, session != nil {
			startCapture()
		}
	}

	/// La capture tourne pendant toute la session, pour que le raccourci de bascule
	/// fonctionne quelle que soit l'application au premier plan.
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
		guard let session, session.followerCount > 0 else {
			announce("Aucun PC connecté.")
			return
		}
		guard capture.isRunning else {
			announce("Le clavier ne peut pas être capturé : accordez d'abord les autorisations.")
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
		tones.beep(hz: 880, milliseconds: 60, left: 50, right: 50)
		announce("Contrôle du PC.")
	}

	private func switchToMac(announcing: Bool) {
		guard isControllingPC else { return }
		capture.setRemote(false)
		isControllingPC = false
		do {
			try CapsLockRemap.remove()
		} catch {
			announce("Verrouillage majuscules n'a pas pu être rétablie : \(error.localizedDescription) Un redémarrage la rétablira.")
			return
		}
		if announcing {
			tones.beep(hz: 440, milliseconds: 60, left: 50, right: 50)
			announce("Contrôle du Mac.")
		}
	}

	private func shutdown() {
		switchToMac(announcing: false)
		capture.stop()
		session?.stop()
	}

	// MARK: - Annonces

	/// Met à jour l'état affiché et le fait annoncer par VoiceOver.
	func announce(_ text: String) {
		status = text
		var announcement = AttributedString(text)
		announcement.accessibilitySpeechAnnouncementPriority = .high
		AccessibilityNotification.Announcement(announcement).post()
	}
}

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

	private(set) var phase = Phase.idle
	private(set) var status = "Non connecté."
	var pendingTrust: PendingTrust?

	var isActive: Bool { phase != .idle }

	var wordsPerMinute: Int {
		didSet {
			speech.wordsPerMinute = wordsPerMinute
			UserDefaults.standard.set(wordsPerMinute, forKey: Self.wordsPerMinuteKey)
		}
	}

	@ObservationIgnored private let speech: SpeechOutput
	@ObservationIgnored private let tones = TonePlayer()
	@ObservationIgnored private let trustStore = TrustStore()
	@ObservationIgnored private var session: LeaderSession?

	private static let wordsPerMinuteKey = "wordsPerMinute"

	init() {
		let saved = UserDefaults.standard.integer(forKey: Self.wordsPerMinuteKey)
		let wordsPerMinute = saved > 0 ? saved : 300
		self.wordsPerMinute = wordsPerMinute
		speech = SpeechOutput(wordsPerMinute: wordsPerMinute)
	}

	static let publicServer = "nvdaremote.com"

	/// Se connecte avec le serveur et la clé saisis. Un lien `nvdaremote://` collé
	/// dans le champ de clé l'emporte sur le serveur saisi.
	/// - Returns: la connexion retenue, pour que la fenêtre puisse réafficher le lien éclaté
	///   en serveur et clé ; `nil` si la saisie est invalide.
	@discardableResult
	func connect(server: String, keyOrLink: String) -> ConnectionInfo? {
		let keyOrLink = keyOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
		do {
			let info = keyOrLink.lowercased().hasPrefix("nvdaremote:")
				? try ConnectionInfo(url: keyOrLink)
				: try ConnectionInfo(server: server, key: keyOrLink)
			start(info)
			return info
		} catch {
			announce(error.localizedDescription)
			return nil
		}
	}

	func disconnect() {
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
			phase = .waitingForComputer
			announce("PC déconnecté. En attente de son retour.")
		case let .disconnected(reason, willRetry):
			phase = willRetry ? .connecting : .idle
			announce("Connexion perdue : \(reason).\(willRetry ? " Nouvel essai dans 5 secondes." : "")")
		case let .message(text):
			announce(text)
		case let .ended(reason):
			session = nil
			phase = .idle
			announce("Arrêt : \(reason).")
		case let .untrustedCertificate(fingerprint):
			session = nil
			phase = .idle
			status = "Certificat à vérifier."
			pendingTrust = PendingTrust(info: info, fingerprint: fingerprint)
		}
	}

	/// Met à jour l'état affiché et le fait annoncer par VoiceOver.
	private func announce(_ text: String) {
		status = text
		var announcement = AttributedString(text)
		announcement.accessibilitySpeechAnnouncementPriority = .high
		AccessibilityNotification.Announcement(announcement).post()
	}
}

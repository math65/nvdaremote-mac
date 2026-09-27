import Foundation

/// Session côté contrôleur : rejoint le canal et restitue sur le Mac ce que le PC envoie.
///
/// Pendant de `LeaderSession` dans `_remoteClient/session.py`.
@MainActor
public final class LeaderSession {
	public enum Event: Equatable, Sendable {
		case connecting
		case connected
		/// Canal rejoint ; `followers` est le nombre de PC déjà présents.
		case joined(followers: Int)
		case followerJoined
		case followerLeft
		case disconnected(reason: String, willRetry: Bool)
		case message(String)
		/// La session s'est arrêtée d'elle-même et ne reprendra pas.
		case ended(reason: String)
		case untrustedCertificate(fingerprint: String)
	}

	public var onEvent: ((Event) -> Void)?
	/// Chaque ligne reçue, pour le débogage.
	public var onRawLine: ((String) -> Void)?

	private let info: ConnectionInfo
	private let transport: RelayTransport
	private let speech: SpeechOutput
	private let tones: TonePlayer
	private var followers: Set<Int> = []

	public init(info: ConnectionInfo, trustedFingerprint: String?, speech: SpeechOutput, tones: TonePlayer) {
		self.info = info
		self.speech = speech
		self.tones = tones
		transport = RelayTransport(info: info, trustedFingerprint: trustedFingerprint)
		transport.onEvent = { [weak self] event in self?.handle(event) }
		transport.onLine = { [weak self] line in self?.handle(line) }
	}

	public func start() {
		onEvent?(.connecting)
		transport.start()
	}

	public func stop() {
		transport.stop()
		speech.cancel()
		followers.removeAll()
	}

	// MARK: - Transport

	private func handle(_ event: RelayTransport.Event) {
		switch event {
		case .connected:
			transport.send(OutgoingMessage.protocolVersion())
			transport.send(OutgoingMessage.join(channel: info.key))
			speech.warmUp()
			onEvent?(.connected)
		case let .disconnected(reason, willRetry):
			followers.removeAll()
			speech.cancel()
			onEvent?(.disconnected(reason: reason, willRetry: willRetry))
		case let .untrustedCertificate(fingerprint):
			onEvent?(.untrustedCertificate(fingerprint: fingerprint))
		}
	}

	// MARK: - Messages

	private func handle(_ line: Data) {
		if let onRawLine {
			onRawLine(String(decoding: line, as: UTF8.self))
		}
		guard let message = try? IncomingMessage.parse(line) else { return }
		switch message {
		case let .speak(sequence, priority):
			speech.speak(sequence, priority: priority)
		case .cancel:
			speech.cancel()
		case let .pauseSpeech(paused):
			speech.setPaused(paused)
		case let .tone(hz, milliseconds, left, right):
			tones.beep(hz: hz, milliseconds: milliseconds, left: left, right: right)
		case let .channelJoined(clients):
			followers = Set(clients.filter(\.isFollower).map(\.id))
			if !followers.isEmpty {
				transport.send(OutgoingMessage.brailleInfo())
			}
			onEvent?(.joined(followers: followers.count))
		case let .clientJoined(client) where client.isFollower:
			followers.insert(client.id)
			// Le PC ajuste son braille à chaque arrivée : on redit qu'on n'en a pas.
			transport.send(OutgoingMessage.brailleInfo())
			onEvent?(.followerJoined)
		case let .clientLeft(client) where client.isFollower:
			if followers.remove(client.id) != nil {
				speech.cancel()
				onEvent?(.followerLeft)
			}
		case let .motd(text) where !text.isEmpty:
			onEvent?(.message(text))
		case .versionMismatch:
			end("le serveur ne prend pas en charge la version \(currentProtocolVersion) du protocole")
		case let .error(message):
			end(message == "incorrect_password" ? "clé incorrecte" : "erreur du serveur : \(message)")
		case .nvdaNotConnected:
			onEvent?(.message("NVDA n'est pas connecté sur le PC"))
		case .clientJoined, .clientLeft, .motd, .wave, .ping, .other:
			// `wave` : les sons de NVDA viendront avec leurs fichiers, dans une étape suivante.
			break
		}
	}

	private func end(_ reason: String) {
		stop()
		onEvent?(.ended(reason: reason))
	}
}

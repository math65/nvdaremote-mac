import CryptoKit
import Foundation
import Network
import os

/// Connexion TLS au relais, découpée en lignes, avec reconnexion automatique.
///
/// Le certificat est d'abord vérifié normalement, ce qui suffit pour `nvdaremote.com`.
/// Un serveur NVDA « Héberger localement » présente un certificat auto-signé : il n'est
/// accepté que si son empreinte SHA-256 est celle qu'on a déclarée de confiance, comme
/// dans NVDA. Sinon la connexion s'arrête et l'empreinte est remontée pour que
/// l'utilisateur décide.
@MainActor
public final class RelayTransport {
	public enum Event: Equatable, Sendable {
		case connected
		case disconnected(reason: String, willRetry: Bool)
		case untrustedCertificate(fingerprint: String)
	}

	public static let reconnectDelay: Duration = .seconds(5)

	public var onEvent: ((Event) -> Void)?
	public var onLine: ((Data) -> Void)?

	private let info: ConnectionInfo
	private let trustedFingerprint: String?
	private var connection: NWConnection?
	private var framer = LineFramer()
	private var reconnectTask: Task<Void, Never>?
	private var running = false
	private var ready = false

	public init(info: ConnectionInfo, trustedFingerprint: String? = nil) {
		self.info = info
		self.trustedFingerprint = trustedFingerprint.map(normalizeFingerprint)
	}

	public func start() {
		guard !running else { return }
		running = true
		connect()
	}

	public func stop() {
		running = false
		reconnectTask?.cancel()
		reconnectTask = nil
		if let connection {
			drop(connection)
		}
	}

	/// Envoie une ligne déjà encodée. Comme dans NVDA, rien n'est mis en file hors connexion.
	public func send(_ data: Data) {
		guard ready, let connection else { return }
		connection.send(content: data, completion: .contentProcessed { _ in })
	}

	// MARK: - Cycle de vie de la connexion

	private func connect() {
		guard running, let port = NWEndpoint.Port(rawValue: info.port) else { return }
		let rejected = RejectedFingerprint()
		let parameters = Self.parameters(trustedFingerprint: trustedFingerprint, rejected: rejected)
		let connection = NWConnection(host: NWEndpoint.Host(info.host), port: port, using: parameters)
		self.connection = connection
		framer.reset()
		ready = false
		connection.stateUpdateHandler = { [weak self] state in
			MainActor.assumeIsolated {
				self?.handle(state, of: connection, rejected: rejected)
			}
		}
		connection.start(queue: .main)
	}

	private func handle(_ state: NWConnection.State, of connection: NWConnection, rejected: RejectedFingerprint) {
		guard connection === self.connection else { return }
		switch state {
		case .ready:
			ready = true
			onEvent?(.connected)
			receive(on: connection)
		case let .waiting(error), let .failed(error):
			fail(connection, reason: describe(error), rejected: rejected)
		default:
			break
		}
	}

	private func receive(on connection: NWConnection) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
			MainActor.assumeIsolated {
				guard let self, connection === self.connection else { return }
				if let data, !data.isEmpty {
					for line in self.framer.append(data) {
						// Un message peut provoquer l'arrêt : on ne livre plus rien ensuite.
						guard connection === self.connection else { return }
						self.onLine?(line)
					}
				}
				if let error {
					self.fail(connection, reason: describe(error), rejected: nil)
				} else if isComplete {
					self.fail(connection, reason: "le serveur a fermé la connexion", rejected: nil)
				} else {
					self.receive(on: connection)
				}
			}
		}
	}

	private func fail(_ connection: NWConnection, reason: String, rejected: RejectedFingerprint?) {
		guard connection === self.connection else { return }
		drop(connection)
		if let fingerprint = rejected?.value {
			running = false
			onEvent?(.untrustedCertificate(fingerprint: fingerprint))
			return
		}
		onEvent?(.disconnected(reason: reason, willRetry: running))
		scheduleReconnect()
	}

	private func drop(_ connection: NWConnection) {
		connection.stateUpdateHandler = nil
		connection.cancel()
		if connection === self.connection {
			self.connection = nil
			ready = false
		}
	}

	private func scheduleReconnect() {
		guard running else { return }
		reconnectTask?.cancel()
		reconnectTask = Task { [weak self] in
			try? await Task.sleep(for: Self.reconnectDelay)
			guard !Task.isCancelled else { return }
			self?.connect()
		}
	}

	// MARK: - Paramètres TCP et TLS

	private nonisolated static func parameters(
		trustedFingerprint: String?,
		rejected: RejectedFingerprint,
	) -> NWParameters {
		let tls = NWProtocolTLS.Options()
		let security = tls.securityProtocolOptions
		sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
		sec_protocol_options_set_verify_block(security, { _, trust, complete in
			let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
			if SecTrustEvaluateWithError(secTrust, nil) {
				complete(true)
				return
			}
			guard let fingerprint = leafFingerprint(of: secTrust) else {
				complete(false)
				return
			}
			if fingerprint == trustedFingerprint {
				complete(true)
			} else {
				rejected.value = fingerprint
				complete(false)
			}
		}, DispatchQueue.global(qos: .userInitiated))

		let tcp = NWProtocolTCP.Options()
		tcp.noDelay = true
		tcp.enableKeepalive = true
		tcp.keepaliveIdle = 60
		return NWParameters(tls: tls, tcp: tcp)
	}

	private nonisolated static func leafFingerprint(of trust: SecTrust) -> String? {
		guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
			let leaf = chain.first
		else { return nil }
		let der = SecCertificateCopyData(leaf) as Data
		return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
	}
}

/// Empreinte du certificat refusé, écrite par le bloc de vérification TLS
/// sur une file d'arrière-plan et lue ensuite sur le fil principal.
private final class RejectedFingerprint: Sendable {
	private let storage = OSAllocatedUnfairLock<String?>(initialState: nil)

	var value: String? {
		get { storage.withLock { $0 } }
		set { storage.withLock { $0 = newValue } }
	}
}

/// Met une empreinte au format de NVDA : SHA-256 en hexadécimal minuscule, sans séparateur.
public func normalizeFingerprint(_ fingerprint: String) -> String {
	fingerprint.lowercased().filter(\.isHexDigit)
}

private func describe(_ error: NWError) -> String {
	switch error {
	case .posix(.ECONNREFUSED): "connexion refusée"
	case .posix(.ETIMEDOUT): "délai dépassé"
	case .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): "réseau injoignable"
	case .posix(.ECONNRESET): "connexion interrompue par le serveur"
	case .dns: "serveur introuvable"
	case .tls: "échec de la négociation TLS"
	default: error.localizedDescription
	}
}

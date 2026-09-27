import CryptoKit
import Foundation
import Network
import os

/// TLS connection to the relay, split into lines, with automatic reconnection.
///
/// The certificate is first verified normally, which is enough for `nvdaremote.com`.
/// An NVDA "Host locally" server presents a self-signed certificate: it is only
/// accepted if its SHA-256 fingerprint matches one previously marked as trusted, as
/// in NVDA. Otherwise the connection stops and the fingerprint is reported so the
/// user can decide.
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

	/// Sends an already encoded line. As in NVDA, nothing is queued while disconnected.
	public func send(_ data: Data) {
		guard ready, let connection else { return }
		connection.send(content: data, completion: .contentProcessed { _ in })
	}

	// MARK: - Connection lifecycle

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
						// A message may cause a stop: deliver nothing more after that.
						guard connection === self.connection else { return }
						self.onLine?(line)
					}
				}
				if let error {
					self.fail(connection, reason: describe(error), rejected: nil)
				} else if isComplete {
					self.fail(connection, reason: localized("the server closed the connection"), rejected: nil)
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

	// MARK: - TCP and TLS parameters

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
		// NVDA uses keepalive with a 60-second idle time and a 2-second interval, so a dead
		// connection is noticed in about a minute and a half rather than ten minutes.
		tcp.keepaliveIdle = 60
		tcp.keepaliveInterval = 2
		tcp.keepaliveCount = 10
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

/// Fingerprint of the rejected certificate, written by the TLS verify block
/// on a background queue and then read on the main thread.
private final class RejectedFingerprint: Sendable {
	private let storage = OSAllocatedUnfairLock<String?>(initialState: nil)

	var value: String? {
		get { storage.withLock { $0 } }
		set { storage.withLock { $0 = newValue } }
	}
}

/// Formats a fingerprint the way NVDA does: SHA-256 in lowercase hexadecimal, without separators.
public func normalizeFingerprint(_ fingerprint: String) -> String {
	fingerprint.lowercased().filter(\.isHexDigit)
}

private func describe(_ error: NWError) -> String {
	switch error {
	case .posix(.ECONNREFUSED): localized("connection refused")
	case .posix(.ETIMEDOUT): localized("timed out")
	case .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): localized("network unreachable")
	case .posix(.ECONNRESET): localized("connection reset by the server")
	case .dns: localized("server not found")
	case .tls: localized("TLS negotiation failed")
	default: error.localizedDescription
	}
}

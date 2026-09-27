import Foundation

/// Où se connecter et avec quelle clé.
///
/// Le Mac est toujours contrôleur (`master` dans le protocole) : ce type ne porte
/// donc pas de mode, il refuse seulement les liens prévus pour l'autre rôle.
public struct ConnectionInfo: Equatable, Sendable {
	public static let defaultPort: UInt16 = 6837

	public var host: String
	public var port: UInt16
	public var key: String

	public init(host: String, port: UInt16 = ConnectionInfo.defaultPort, key: String) {
		self.host = host
		self.port = port
		self.key = key
	}

	/// Adresse au format `hôte:port`, utilisée comme clé pour les empreintes de confiance.
	public var address: String {
		host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
	}

	/// Lit un serveur saisi à la main : `hôte`, `hôte:port`, `[ipv6]:port` ou une IPv6 seule.
	public init(server: String, key: String) throws(ConnectionInfoError) {
		let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
		let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !server.isEmpty else { throw .missingHost }
		guard !key.isEmpty else { throw .missingKey }

		var host = server
		var rawPort: Substring?
		if server.hasPrefix("["), let close = server.firstIndex(of: "]") {
			host = String(server[server.index(after: server.startIndex)..<close])
			let rest = server[server.index(after: close)...]
			if rest.hasPrefix(":") {
				rawPort = rest.dropFirst()
			} else if !rest.isEmpty {
				throw .invalidPort
			}
		} else if server.filter({ $0 == ":" }).count == 1, let colon = server.firstIndex(of: ":") {
			host = String(server[..<colon])
			rawPort = server[server.index(after: colon)...]
		}
		guard !host.isEmpty else { throw .missingHost }

		var port = Self.defaultPort
		if let rawPort {
			guard let parsed = UInt16(rawPort), parsed != 0 else { throw .invalidPort }
			port = parsed
		}
		self.init(host: host, port: port, key: key)
	}

	/// Le serveur tel qu'on l'afficherait dans un champ de saisie : le port n'apparaît que s'il n'est pas celui par défaut.
	public var serverDescription: String {
		port == Self.defaultPort ? host : address
	}

	/// Lit un lien `nvdaremote://hôte:port/?key=…&mode=master`,
	/// tel que le produit « Copier le lien » sur le PC contrôlé.
	public init(url string: String) throws(ConnectionInfoError) {
		guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
			components.scheme?.lowercased() == "nvdaremote"
		else { throw .notARemoteLink }

		var host = components.host ?? ""
		if host.hasPrefix("["), host.hasSuffix("]") {
			host = String(host.dropFirst().dropLast())
		}
		guard !host.isEmpty else { throw .missingHost }

		func query(_ name: String) -> String? {
			components.queryItems?.first { $0.name == name }?.value
		}
		guard let key = query("key"), !key.isEmpty else { throw .missingKey }

		switch query("mode")?.lowercased() {
		case nil, "", "master", "leader":
			break
		case "slave", "follower":
			throw .followerLink
		case let other?:
			throw .unknownMode(other)
		}

		let port: UInt16
		if let rawPort = components.port {
			guard let valid = UInt16(exactly: rawPort), valid != 0 else { throw .invalidPort }
			port = valid
		} else {
			port = Self.defaultPort
		}
		self.init(host: host, port: port, key: key)
	}
}

public enum ConnectionInfoError: Error, Equatable, LocalizedError {
	case notARemoteLink
	case missingHost
	case missingKey
	case invalidPort
	case followerLink
	case unknownMode(String)

	public var errorDescription: String? {
		switch self {
		case .notARemoteLink: "Ce n'est pas un lien nvdaremote://."
		case .missingHost: "Le lien ne contient pas d'adresse de serveur."
		case .missingKey: "Le lien ne contient pas de clé."
		case .invalidPort: "Le port du lien n'est pas valide."
		case .followerLink: "Ce lien sert à être contrôlé, pas à contrôler. Copiez le lien depuis le PC à contrôler."
		case let .unknownMode(mode): "Mode inconnu dans le lien : \(mode)."
		}
	}
}

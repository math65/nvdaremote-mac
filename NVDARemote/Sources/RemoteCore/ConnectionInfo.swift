import Foundation

/// Where to connect and with which key.
///
/// The Mac is always the controlling side (`master` in the protocol), so this type
/// carries no mode; it only rejects links meant for the other role.
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

	/// Address in `host:port` form, used as the key for trusted fingerprints.
	public var address: String {
		host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
	}

	/// Parses a manually entered server: `host`, `host:port`, `[ipv6]:port` or a bare IPv6 address.
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

	/// The server as it would appear in a text field: the port is shown only if it is not the default one.
	public var serverDescription: String {
		port == Self.defaultPort ? host : address
	}

	/// Parses an `nvdaremote://host:port/?key=…&mode=master` link,
	/// as produced by "Copy link" on the controlled PC.
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
		case .notARemoteLink: localized("This is not an nvdaremote:// link.")
		case .missingHost: localized("No server address was given.")
		case .missingKey: localized("No key was given.")
		case .invalidPort: localized("The port is not valid.")
		case .followerLink: localized("This link is for being controlled, not for controlling. Copy the link from the computer to control.")
		case let .unknownMode(mode): localized("Unknown mode in link: \(mode).")
		}
	}
}

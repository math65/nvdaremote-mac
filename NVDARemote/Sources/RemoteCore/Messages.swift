import Foundation

/// Version du protocole Remote Access annoncée à la connexion.
public let currentProtocolVersion = 2

/// Un client présent sur le canal, tel que le relais le décrit.
public struct RemoteClient: Equatable, Sendable {
	public var id: Int
	/// `slave` pour un PC contrôlé, `master` pour un contrôleur.
	public var connectionType: String

	public var isFollower: Bool { connectionType == "slave" }

	public init(id: Int, connectionType: String) {
		self.id = id
		self.connectionType = connectionType
	}

	init?(json: Any?) {
		guard let dict = json as? [String: Any],
			let id = (dict["id"] as? NSNumber)?.intValue,
			let type = dict["connection_type"] as? String
		else { return nil }
		self.init(id: id, connectionType: type)
	}
}

/// Priorité d'un message `speak`, reprise de `speech.priorities.SpeechPriority` dans NVDA.
public enum SpeechPriority: Int, Sendable {
	case normal = 0
	/// À dire après l'énoncé en cours.
	case next = 1
	/// À dire tout de suite, en coupant la parole en cours.
	case now = 2
}

/// Messages que le contrôleur sait traiter. Tout le reste arrive en `.other`.
public enum IncomingMessage: Equatable, Sendable {
	case channelJoined(clients: [RemoteClient])
	case clientJoined(RemoteClient)
	case clientLeft(RemoteClient)
	case speak(sequence: [SpeechItem], priority: SpeechPriority)
	case cancel
	case pauseSpeech(Bool)
	case tone(hz: Double, milliseconds: Int, left: Int, right: Int)
	case wave(fileName: String)
	case motd(String)
	case versionMismatch
	case error(String)
	case nvdaNotConnected
	case ping
	case other(type: String)

	/// Décode une ligne reçue. Échoue seulement si ce n'est pas un objet JSON avec un `type`.
	public static func parse(_ line: Data) throws(MessageError) -> IncomingMessage {
		guard let object = try? JSONSerialization.jsonObject(with: line),
			let dict = object as? [String: Any],
			let type = dict["type"] as? String
		else { throw .malformed }

		func int(_ key: String, default value: Int) -> Int {
			(dict[key] as? NSNumber)?.intValue ?? value
		}

		switch type {
		case "channel_joined":
			let clients = (dict["clients"] as? [Any] ?? []).compactMap(RemoteClient.init(json:))
			return .channelJoined(clients: clients)
		case "client_joined", "client_left":
			guard let client = RemoteClient(json: dict["client"]) else { return .other(type: type) }
			return type == "client_joined" ? .clientJoined(client) : .clientLeft(client)
		case "speak":
			let sequence = SpeechItem.parseSequence(dict["sequence"] as? [Any] ?? [])
			let priority = SpeechPriority(rawValue: int("priority", default: 0)) ?? .normal
			return .speak(sequence: sequence, priority: priority)
		case "cancel":
			return .cancel
		case "pause_speech":
			return .pauseSpeech((dict["switch"] as? NSNumber)?.boolValue ?? false)
		case "tone":
			guard let hz = (dict["hz"] as? NSNumber)?.doubleValue else { return .other(type: type) }
			return .tone(
				hz: hz,
				milliseconds: int("length", default: 0),
				left: int("left", default: 50),
				right: int("right", default: 50),
			)
		case "wave":
			return .wave(fileName: dict["fileName"] as? String ?? "")
		case "motd":
			return .motd(dict["motd"] as? String ?? "")
		case "version_mismatch":
			return .versionMismatch
		case "error":
			return .error(dict["message"] as? String ?? "")
		case "nvda_not_connected":
			return .nvdaNotConnected
		case "ping":
			return .ping
		default:
			return .other(type: type)
		}
	}
}

public enum MessageError: Error {
	case malformed
}

/// Messages envoyés par le contrôleur, déjà encodés et terminés par `\n`.
public enum OutgoingMessage {
	public static func protocolVersion(_ version: Int = currentProtocolVersion) -> Data {
		encode(["type": "protocol_version", "version": version])
	}

	public static func join(channel: String) -> Data {
		encode(["type": "join", "channel": channel, "connection_type": "master"])
	}

	/// Avec `numCells` à 0, le PC n'envoie jamais de cellules braille.
	public static func brailleInfo(name: String = "noBraille", numCells: Int = 0) -> Data {
		encode(["type": "set_braille_info", "name": name, "numCells": numCells])
	}

	static func encode(_ object: [String: Any]) -> Data {
		// Les dictionnaires ci-dessus ne contiennent que des chaînes et des entiers :
		// la sérialisation ne peut pas échouer.
		var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		data.append(0x0A)
		return data
	}
}

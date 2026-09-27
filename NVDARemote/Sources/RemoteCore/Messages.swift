import Foundation

/// Remote Access protocol version announced when connecting.
public let currentProtocolVersion = 2

/// A client present on the channel, as described by the relay.
public struct RemoteClient: Equatable, Sendable {
	public var id: Int
	/// `slave` for a controlled PC, `master` for a controller.
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

/// Priority of a `speak` message, taken from `speech.priorities.SpeechPriority` in NVDA.
public enum SpeechPriority: Int, Sendable {
	case normal = 0
	/// Spoken after the current utterance.
	case next = 1
	/// Spoken immediately, interrupting the current speech.
	case now = 2
}

/// Messages the controller knows how to handle. Everything else arrives as `.other`.
public enum IncomingMessage: Equatable, Sendable {
	case channelJoined(clients: [RemoteClient])
	case clientJoined(RemoteClient)
	case clientLeft(RemoteClient)
	case speak(sequence: [SpeechItem], priority: SpeechPriority)
	case cancel
	case pauseSpeech(Bool)
	case tone(hz: Double, milliseconds: Int, left: Int, right: Int)
	case wave(fileName: String)
	case clipboardText(String)
	/// One line of braille cells, bits = dots 1 to 8.
	case display(cells: [Int])
	case motd(String)
	case versionMismatch
	case error(String)
	case nvdaNotConnected
	case ping
	case other(type: String)

	/// Decodes a received line. Fails only if it is not a JSON object with a `type`.
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
		case "display":
			let cells = (dict["cells"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
			return .display(cells: cells)
		case "wave":
			return .wave(fileName: dict["fileName"] as? String ?? "")
		case "set_clipboard_text":
			return .clipboardText(dict["text"] as? String ?? "")
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

/// Messages sent by the controller, already encoded and terminated by `\n`.
public enum OutgoingMessage {
	public static func protocolVersion(_ version: Int = currentProtocolVersion) -> Data {
		encode(["type": "protocol_version", "version": version])
	}

	public static func join(channel: String) -> Data {
		encode(["type": "join", "channel": channel, "connection_type": "master"])
	}

	/// With `numCells` set to 0, the PC never sends braille cells.
	public static func brailleInput(_ gesture: BrailleGesture) -> Data {
		var fields = gesture.fields
		fields["type"] = "braille_input"
		return encode(fields)
	}

	public static func brailleInfo(name: String = "noBraille", numCells: Int = 0) -> Data {
		encode(["type": "set_braille_info", "name": name, "numCells": numCells])
	}

	public static func clipboardText(_ text: String) -> Data {
		encode(["type": "set_clipboard_text", "text": text])
	}

	/// A key pressed or released. The PC computes the scan code itself.
	public static func key(_ key: WindowsKey, pressed: Bool) -> Data {
		encode(["type": "key", "vk_code": key.vk, "extended": key.extended, "pressed": pressed])
	}

	static func encode(_ object: [String: Any]) -> Data {
		// The dictionaries above only contain strings, integers, booleans and arrays of them:
		// serialization cannot fail.
		var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		data.append(0x0A)
		return data
	}
}

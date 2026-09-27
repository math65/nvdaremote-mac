import Foundation
import Testing

@testable import RemoteCore

@Suite struct ConnectionInfoTests {
	@Test func readsLinkCopiedFromControlledPC() throws {
		let info = try ConnectionInfo(url: "nvdaremote://nvdaremote.com:6837/?key=abc-123&mode=master")
		#expect(info == ConnectionInfo(host: "nvdaremote.com", port: 6837, key: "abc-123"))
		#expect(info.address == "nvdaremote.com:6837")
	}

	@Test func defaultsPortAndAcceptsMissingMode() throws {
		let info = try ConnectionInfo(url: "nvdaremote://192.168.1.20/?key=k")
		#expect(info.port == ConnectionInfo.defaultPort)
		#expect(info.host == "192.168.1.20")
	}

	@Test func stripsIPv6Brackets() throws {
		let info = try ConnectionInfo(url: "nvdaremote://[::1]:6837/?key=k&mode=master")
		#expect(info.host == "::1")
		#expect(info.address == "[::1]:6837")
	}

	@Test func readsTypedServer() throws {
		#expect(try ConnectionInfo(server: " nvdaremote.com ", key: " k ")
			== ConnectionInfo(host: "nvdaremote.com", port: 6837, key: "k"))
		#expect(try ConnectionInfo(server: "192.168.1.20:7000", key: "k").port == 7000)
		#expect(try ConnectionInfo(server: "[fe80::1]:7000", key: "k")
			== ConnectionInfo(host: "fe80::1", port: 7000, key: "k"))
		#expect(try ConnectionInfo(server: "fe80::1", key: "k").host == "fe80::1")
		#expect(try ConnectionInfo(server: "monpc.local:6837", key: "k").serverDescription == "monpc.local")
		#expect(try ConnectionInfo(server: "monpc.local:7000", key: "k").serverDescription == "monpc.local:7000")
	}

	@Test func rejectsBadTypedServer() {
		#expect(throws: ConnectionInfoError.missingHost) { try ConnectionInfo(server: "  ", key: "k") }
		#expect(throws: ConnectionInfoError.missingHost) { try ConnectionInfo(server: ":6837", key: "k") }
		#expect(throws: ConnectionInfoError.missingKey) { try ConnectionInfo(server: "h", key: "") }
		#expect(throws: ConnectionInfoError.invalidPort) { try ConnectionInfo(server: "h:abc", key: "k") }
		#expect(throws: ConnectionInfoError.invalidPort) { try ConnectionInfo(server: "h:0", key: "k") }
		#expect(throws: ConnectionInfoError.invalidPort) { try ConnectionInfo(server: "[::1]x", key: "k") }
	}

	@Test func rejectsBadLinks() {
		#expect(throws: ConnectionInfoError.notARemoteLink) { try ConnectionInfo(url: "https://nvdaremote.com") }
		#expect(throws: ConnectionInfoError.missingKey) { try ConnectionInfo(url: "nvdaremote://h/?mode=master") }
		#expect(throws: ConnectionInfoError.followerLink) {
			try ConnectionInfo(url: "nvdaremote://h/?key=k&mode=slave")
		}
	}
}

@Suite struct LineFramerTests {
	@Test func splitsAcrossChunks() {
		var framer = LineFramer()
		#expect(framer.append(Data("{\"type\":\"can".utf8)).isEmpty)
		let lines = framer.append(Data("cel\"}\n\n{\"type\":\"ping\"}\n{\"ty".utf8))
		#expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"type\":\"cancel\"}", "{\"type\":\"ping\"}"])
		let rest = framer.append(Data("pe\":\"x\"}\n".utf8))
		#expect(rest.map { String(decoding: $0, as: UTF8.self) } == ["{\"type\":\"x\"}"])
	}

	@Test func resetDropsPartialLine() {
		var framer = LineFramer()
		_ = framer.append(Data("partiel".utf8))
		framer.reset()
		#expect(framer.append(Data("ok\n".utf8)) == [Data("ok".utf8)])
	}
}

@Suite struct IncomingMessageTests {
	func parse(_ json: String) throws -> IncomingMessage {
		try IncomingMessage.parse(Data(json.utf8))
	}

	/// Real example reproduced in docs/feasibility-study.md, section 2.6.
	@Test func decodesRealSpeakMessage() throws {
		let message = try parse("""
			{"type": "speak", "priority": 0, "origin": 3,
			 "sequence": [["LangChangeCommand", {"lang": "fr_FR", "isDefault": false}],
			              "Bureau  liste",
			              ["IndexCommand", {"index": 12}],
			              ["EndUtteranceCommand", {}]]}
			""")
		#expect(message == .speak(
			sequence: [.language("fr_FR"), .text("Bureau  liste"), .index(12), .endUtterance],
			priority: .normal,
		))
	}

	@Test func ignoresUnknownSpeechCommands() throws {
		let message = try parse("""
			{"type":"speak","priority":2,"sequence":[["PitchCommand",{"_offset":10}],["FutureCommand",{}],"oui"]}
			""")
		#expect(message == .speak(sequence: [.text("oui")], priority: .now))
	}

	@Test func decodesSessionMessages() throws {
		#expect(try parse(#"{"type":"channel_joined","channel":"k","user_ids":[3],"clients":[{"id":3,"connection_type":"slave"}]}"#)
			== .channelJoined(clients: [RemoteClient(id: 3, connectionType: "slave")]))
		#expect(try parse(#"{"type":"channel_joined","channel":"k"}"#) == .channelJoined(clients: []))
		#expect(try parse(#"{"type":"client_left","user_id":4,"client":{"id":4,"connection_type":"master"},"origin":4}"#)
			== .clientLeft(RemoteClient(id: 4, connectionType: "master")))
		#expect(try parse(#"{"type":"tone","hz":440.5,"length":50,"left":20,"right":80}"#)
			== .tone(hz: 440.5, milliseconds: 50, left: 20, right: 80))
		#expect(try parse(#"{"type":"pause_speech","switch":true}"#) == .pauseSpeech(true))
		#expect(try parse(#"{"type":"error","message":"incorrect_password"}"#) == .error("incorrect_password"))
		#expect(try parse(#"{"type":"key","vk_code":65}"#) == .other(type: "key"))
	}

	@Test func rejectsNonMessages() {
		#expect(throws: MessageError.self) { try parse("pas du json") }
		#expect(throws: MessageError.self) { try parse(#"{"sans":"type"}"#) }
	}
}

@Suite struct OutgoingMessageTests {
	func decode(_ data: Data) throws -> [String: AnyHashable] {
		#expect(data.last == 0x0A)
		return try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
	}

	@Test func handshake() throws {
		#expect(try decode(OutgoingMessage.protocolVersion()) == ["type": "protocol_version", "version": 2])
		#expect(try decode(OutgoingMessage.join(channel: "clé"))
			== ["type": "join", "channel": "clé", "connection_type": "master"])
		#expect(try decode(OutgoingMessage.brailleInfo())
			== ["type": "set_braille_info", "name": "noBraille", "numCells": 0])
	}
}

@Suite struct SpeechSegmentTests {
	@Test func joinsTextAndSplitsOnLanguage() {
		let segments = SpeechSegment.segments(from: [
			.text("Lien"), .text("Accueil"), .index(1),
			.language("en_US"), .text("Home"),
			.language(nil), .text("visité"), .endUtterance,
		])
		#expect(segments == [
			SpeechSegment(text: "Lien Accueil"),
			SpeechSegment(text: "Home", language: "en-US"),
			SpeechSegment(text: "visité"),
		])
	}

	@Test func attachesPauseToPreviousSegment() {
		let segments = SpeechSegment.segments(from: [
			.pause(milliseconds: 100), .text("un"), .pause(milliseconds: 250), .text("deux"),
		])
		#expect(segments == [
			SpeechSegment(text: "un", pauseAfterMilliseconds: 250),
			SpeechSegment(text: "deux"),
		])
	}

	@Test func dropsBlankText() {
		#expect(SpeechSegment.segments(from: [.text("  "), .endUtterance, .text("")]).isEmpty)
	}

	@Test func rateFollowsMeasuredCurve() {
		#expect(abs(SpeechOutput.rate(forWordsPerMinute: 177) - 0.5) < 0.001)
		#expect(abs(SpeechOutput.rate(forWordsPerMinute: 643) - 1.0) < 0.01)
		#expect(SpeechOutput.rate(forWordsPerMinute: 2000) == 1.0)
	}

	@Test func normalizesFingerprints() {
		#expect(normalizeFingerprint("AB:cd 12") == "abcd12")
	}
}

@Suite struct LocalizationTests {
	/// The code is in English; French comes from the package's string catalog.
	@Test func frenchCatalogIsBundled() throws {
		let path = try #require(Bundle.module.path(forResource: "fr", ofType: "lproj"))
		let french = try #require(Bundle(path: path))
		#expect(french.localizedString(forKey: "incorrect key", value: nil, table: nil) == "clé incorrecte")
		#expect(french.localizedString(forKey: "key %lld", value: nil, table: nil) == "touche %lld")
		#expect(Bundle.module.localizations.contains("fr"))
	}
}

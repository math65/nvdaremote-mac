import Foundation

/// An item of a `speak` sequence, after decoding.
///
/// NVDA serializes its commands as `[ClassName, {attributes}]` pairs among the strings.
/// We keep only what matters for local speech; an unknown class is ignored,
/// as NVDA itself does.
public enum SpeechItem: Equatable, Sendable {
	case text(String)
	/// Language in NVDA format (`fr_FR`), or `nil` to return to the default language.
	case language(String?)
	case pause(milliseconds: Int)
	case characterMode(Bool)
	case index(Int)
	case endUtterance

	static func parseSequence(_ raw: [Any]) -> [SpeechItem] {
		raw.compactMap { element in
			if let text = element as? String {
				return .text(text)
			}
			guard let pair = element as? [Any], pair.count == 2,
				let name = pair[0] as? String
			else { return nil }
			let attributes = pair[1] as? [String: Any] ?? [:]
			return parseCommand(name, attributes)
		}
	}

	private static func parseCommand(_ name: String, _ attributes: [String: Any]) -> SpeechItem? {
		switch name {
		case "LangChangeCommand":
			let isDefault = (attributes["isDefault"] as? NSNumber)?.boolValue ?? false
			let lang = attributes["lang"] as? String
			return .language(isDefault ? nil : lang)
		case "BreakCommand":
			guard let time = (attributes["time"] as? NSNumber)?.intValue else { return nil }
			return .pause(milliseconds: time)
		case "CharacterModeCommand":
			return .characterMode((attributes["state"] as? NSNumber)?.boolValue ?? false)
		case "IndexCommand":
			guard let index = (attributes["index"] as? NSNumber)?.intValue else { return nil }
			return .index(index)
		case "EndUtteranceCommand":
			return .endUtterance
		case "PhonemeCommand":
			// No IPA pronunciation with AVSpeechSynthesizer: keep the fallback text.
			guard let text = attributes["text"] as? String, !text.isEmpty else { return nil }
			return .text(text)
		default:
			// PitchCommand, RateCommand, VolumeCommand: not applied yet.
			return nil
		}
	}
}

/// A chunk to hand to the synthesizer as is: text in a single language.
public struct SpeechSegment: Equatable, Sendable {
	public var text: String
	/// Language in BCP 47 format (`fr-FR`), `nil` for the default voice.
	public var language: String?
	/// Silence to leave before this chunk (only for a pause at the start of a sequence).
	public var pauseBeforeMilliseconds: Int
	/// Silence to leave after this chunk.
	public var pauseAfterMilliseconds: Int

	/// Longest pause honored: a larger `BreakCommand` would stall the speech queue.
	public static let maximumPauseMilliseconds = 10_000

	public init(text: String, language: String? = nil, pauseBeforeMilliseconds: Int = 0, pauseAfterMilliseconds: Int = 0) {
		self.text = text
		self.language = language
		self.pauseBeforeMilliseconds = pauseBeforeMilliseconds
		self.pauseAfterMilliseconds = pauseAfterMilliseconds
	}
}

extension SpeechSegment {
	/// Splits an NVDA sequence into homogeneous chunks.
	///
	/// A language change or the end of an utterance closes the current chunk.
	/// Consecutive strings are joined with a space, as in NVDA.
	/// A pause is attached to the chunk that precedes it, or before the first chunk.
	public static func segments(from items: [SpeechItem]) -> [SpeechSegment] {
		var segments: [SpeechSegment] = []
		var language: String?
		var pieces: [String] = []
		var leadingPause = 0

		func flush() {
			let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
			pieces.removeAll()
			guard !text.isEmpty else { return }
			// A pause before any text is kept as silence before the first chunk.
			segments.append(SpeechSegment(text: text, language: language, pauseBeforeMilliseconds: segments.isEmpty ? leadingPause : 0))
		}

		for item in items {
			switch item {
			case let .text(text):
				pieces.append(text)
			case let .language(lang):
				let bcp47 = lang.map { $0.replacingOccurrences(of: "_", with: "-") }
				if bcp47 != language {
					flush()
					language = bcp47
				}
			case let .pause(milliseconds):
				flush()
				let pause = min(max(milliseconds, 0), SpeechSegment.maximumPauseMilliseconds)
				if segments.isEmpty {
					leadingPause = min(leadingPause + pause, SpeechSegment.maximumPauseMilliseconds)
				} else {
					let last = segments.count - 1
					segments[last].pauseAfterMilliseconds = min(
						segments[last].pauseAfterMilliseconds + pause, SpeechSegment.maximumPauseMilliseconds)
				}
			case .endUtterance:
				flush()
			case .characterMode, .index:
				break
			}
		}
		flush()
		return segments
	}
}

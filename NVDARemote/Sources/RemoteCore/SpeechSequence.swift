import Foundation

/// Un élément d'une séquence `speak`, après décodage.
///
/// NVDA sérialise ses commandes en paires `[NomDeClasse, {attributs}]` au milieu des chaînes.
/// On ne garde que ce qui compte pour la parole locale ; une classe inconnue est ignorée,
/// comme le fait NVDA lui-même.
public enum SpeechItem: Equatable, Sendable {
	case text(String)
	/// Langue au format NVDA (`fr_FR`), ou `nil` pour revenir à la langue par défaut.
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
			// Pas de prononciation IPA avec AVSpeechSynthesizer : on garde le texte de repli.
			guard let text = attributes["text"] as? String, !text.isEmpty else { return nil }
			return .text(text)
		default:
			// PitchCommand, RateCommand, VolumeCommand : pas encore appliquées.
			return nil
		}
	}
}

/// Un morceau à confier tel quel au synthétiseur : un texte dans une seule langue.
public struct SpeechSegment: Equatable, Sendable {
	public var text: String
	/// Langue au format BCP 47 (`fr-FR`), `nil` pour la voix par défaut.
	public var language: String?
	/// Silence à marquer après ce morceau.
	public var pauseAfterMilliseconds: Int

	public init(text: String, language: String? = nil, pauseAfterMilliseconds: Int = 0) {
		self.text = text
		self.language = language
		self.pauseAfterMilliseconds = pauseAfterMilliseconds
	}
}

extension SpeechSegment {
	/// Découpe une séquence NVDA en morceaux homogènes.
	///
	/// Un changement de langue ou une fin d'énoncé ferme le morceau en cours.
	/// Les chaînes consécutives sont jointes par une espace, comme dans NVDA.
	/// Une pause s'ajoute au morceau qui la précède.
	public static func segments(from items: [SpeechItem]) -> [SpeechSegment] {
		var segments: [SpeechSegment] = []
		var language: String?
		var pieces: [String] = []

		func flush() {
			let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
			pieces.removeAll()
			guard !text.isEmpty else { return }
			segments.append(SpeechSegment(text: text, language: language))
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
				if !segments.isEmpty {
					segments[segments.count - 1].pauseAfterMilliseconds += milliseconds
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

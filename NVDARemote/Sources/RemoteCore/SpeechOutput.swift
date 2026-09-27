import AVFoundation

/// Prononce la parole reçue du PC avec le synthétiseur système.
///
/// Suit les consignes de docs/mesures-parole.md : un seul synthétiseur pour la session,
/// coupure en `.immediate`, moteur chauffé à la connexion, et aucune logique
/// appuyée sur `didCancel`, jamais appelé sur macOS 26. La file interne
/// d'`AVSpeechSynthesizer` enchaîne les énoncés sans blanc, on s'en sert telle quelle.
@MainActor
public final class SpeechOutput {
	private let synthesizer = AVSpeechSynthesizer()
	private var defaultVoice: AVSpeechSynthesisVoice?
	private var voicesByLanguage: [String: AVSpeechSynthesisVoice?] = [:]
	private var rate: Float

	/// Débit visé, converti avec la courbe mesurée. S'applique aux énoncés suivants.
	public var wordsPerMinute: Int {
		didSet { rate = Self.rate(forWordsPerMinute: wordsPerMinute) }
	}

	/// - Parameters:
	///   - wordsPerMinute: débit visé, converti avec la courbe mesurée.
	///   - voice: identifiant ou nom de voix ; `nil` choisit la meilleure voix de la langue du système.
	public init(wordsPerMinute: Int = 300, voice: String? = nil) {
		self.wordsPerMinute = wordsPerMinute
		rate = Self.rate(forWordsPerMinute: wordsPerMinute)
		defaultVoice = voice.flatMap(Self.findVoice(named:))
			?? Self.bestVoice(for: AVSpeechSynthesisVoice.currentLanguageCode())
	}

	public var voiceDescription: String {
		guard let voice = defaultVoice else { return "voix système" }
		return "\(voice.name) (\(voice.language))"
	}

	/// Prononce un énoncé muet pour que le premier retour du PC parte sans délai.
	public func warmUp() {
		let utterance = AVSpeechUtterance(string: "a")
		utterance.volume = 0
		utterance.voice = defaultVoice
		synthesizer.speak(utterance)
	}

	public func speak(_ sequence: [SpeechItem], priority: SpeechPriority) {
		let segments = SpeechSegment.segments(from: sequence)
		guard !segments.isEmpty else { return }
		// NVDA reprend ensuite la parole interrompue par une priorité immédiate.
		// On ne le fait pas encore : ce qui était en cours est simplement abandonné.
		if priority == .now {
			cancel()
		}
		for segment in segments {
			synthesizer.speak(utterance(for: segment))
		}
	}

	public func cancel() {
		if synthesizer.isSpeaking || synthesizer.isPaused {
			synthesizer.stopSpeaking(at: .immediate)
		}
	}

	public func setPaused(_ paused: Bool) {
		if paused {
			synthesizer.pauseSpeaking(at: .immediate)
		} else {
			synthesizer.continueSpeaking()
		}
	}

	private func utterance(for segment: SpeechSegment) -> AVSpeechUtterance {
		let utterance = AVSpeechUtterance(string: segment.text)
		utterance.rate = rate
		utterance.voice = segment.language.map(voice(for:)) ?? defaultVoice
		utterance.postUtteranceDelay = TimeInterval(segment.pauseAfterMilliseconds) / 1000
		return utterance
	}

	private func voice(for language: String) -> AVSpeechSynthesisVoice? {
		if let defaultVoice, Self.matches(defaultVoice, language) {
			return defaultVoice
		}
		if let cached = voicesByLanguage[language] {
			return cached ?? defaultVoice
		}
		let found = Self.bestVoice(for: language)
		voicesByLanguage[language] = found
		return found ?? defaultVoice
	}

	// MARK: - Choix des voix et du débit

	/// Débit `AVSpeechUtterance.rate` pour un nombre de mots par minute.
	/// Au-dessus de 0,5, la mesure donne `mots ≈ 177 + (rate - 0,5) × 933`.
	/// En dessous, on suppose une proportionnalité simple.
	public nonisolated static func rate(forWordsPerMinute wpm: Int) -> Float {
		let wpm = Float(max(wpm, 1))
		let rate = wpm >= 177 ? 0.5 + (wpm - 177) / 933 : 0.5 * wpm / 177
		return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
	}

	/// Voix de meilleure qualité pour une langue BCP 47. Accepte une langue seule (`fr`).
	public static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
		let voices = AVSpeechSynthesisVoice.speechVoices()
		let exact = voices.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
		let candidates = exact.isEmpty ? voices.filter { matches($0, language) } : exact
		// À qualité égale, la voix par défaut du système pour cette langue passe devant.
		let systemDefault = AVSpeechSynthesisVoice(language: language)?.identifier
		return candidates.max { a, b in
			if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
			return b.identifier == systemDefault
		}
	}

	public static func findVoice(named nameOrIdentifier: String) -> AVSpeechSynthesisVoice? {
		AVSpeechSynthesisVoice(identifier: nameOrIdentifier)
			?? AVSpeechSynthesisVoice.speechVoices().first {
				$0.name.caseInsensitiveCompare(nameOrIdentifier) == .orderedSame
			}
	}

	private static func matches(_ voice: AVSpeechSynthesisVoice, _ language: String) -> Bool {
		primaryLanguage(voice.language) == primaryLanguage(language)
	}

	private static func primaryLanguage(_ code: String) -> String {
		String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
	}
}

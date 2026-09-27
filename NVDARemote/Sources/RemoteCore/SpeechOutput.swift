import AVFoundation

/// Speaks the speech received from the PC with the system synthesizer.
///
/// Follows the guidelines in docs/speech-measurements.md: a single synthesizer per session,
/// `.immediate` interruption, engine warmed up on connection, and no logic relying
/// on `didCancel`, which is never called on macOS 26. `AVSpeechSynthesizer`'s internal
/// queue chains utterances without gaps, so we use it as is.
@MainActor
public final class SpeechOutput {
	private let synthesizer = AVSpeechSynthesizer()
	private var defaultVoice: AVSpeechSynthesisVoice?
	private var voicesByLanguage: [String: AVSpeechSynthesisVoice?] = [:]
	private var rate: Float

	/// Target rate, converted with the measured curve. Applies to subsequent utterances.
	public var wordsPerMinute: Int {
		didSet { rate = Self.rate(forWordsPerMinute: wordsPerMinute) }
	}

	/// - Parameters:
	///   - wordsPerMinute: target rate, converted with the measured curve.
	///   - voice: voice identifier or name; `nil` picks the best voice for the system language.
	public init(wordsPerMinute: Int = 300, voice: String? = nil) {
		self.wordsPerMinute = wordsPerMinute
		rate = Self.rate(forWordsPerMinute: wordsPerMinute)
		defaultVoice = voice.flatMap(Self.findVoice(named:))
			?? Self.bestVoice(for: AVSpeechSynthesisVoice.currentLanguageCode())
	}

	public var voiceDescription: String {
		guard let voice = defaultVoice else { return localized("system voice") }
		return "\(voice.name) (\(voice.language))"
	}

	/// Speaks a silent utterance so the first speech from the PC starts without delay.
	public func warmUp() {
		let utterance = AVSpeechUtterance(string: "a")
		utterance.volume = 0
		utterance.voice = defaultVoice
		synthesizer.speak(utterance)
	}

	public func speak(_ sequence: [SpeechItem], priority: SpeechPriority) {
		let segments = SpeechSegment.segments(from: sequence)
		guard !segments.isEmpty else { return }
		// NVDA then resumes speech interrupted by an immediate priority.
		// We do not do that yet: whatever was in progress is simply dropped.
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
		// NVDA's cancel also ends a pause: speech that follows must be heard.
		if synthesizer.isPaused {
			synthesizer.continueSpeaking()
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
		utterance.preUtteranceDelay = TimeInterval(segment.pauseBeforeMilliseconds) / 1000
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

	// MARK: - Voice and rate selection

	/// `AVSpeechUtterance.rate` value for a number of words per minute.
	/// Above 0.5, measurements give `words ≈ 177 + (rate - 0.5) × 933`.
	/// Below that, a simple proportional relation is assumed.
	public nonisolated static func rate(forWordsPerMinute wpm: Int) -> Float {
		let wpm = Float(max(wpm, 1))
		let rate = wpm >= 177 ? 0.5 + (wpm - 177) / 933 : 0.5 * wpm / 177
		return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
	}

	/// Highest-quality voice for a BCP 47 language. Accepts a bare language code (`fr`).
	public static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
		let voices = AVSpeechSynthesisVoice.speechVoices()
		let exact = voices.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
		let candidates = exact.isEmpty ? voices.filter { matches($0, language) } : exact
		// At equal quality, the system's default voice for this language comes first.
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

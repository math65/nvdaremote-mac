import Foundation

/// Controller-side session: joins the channel and renders on the Mac what the PC sends.
///
/// Counterpart of `LeaderSession` in `_remoteClient/session.py`.
@MainActor
public final class LeaderSession {
	public enum Event: Equatable, Sendable {
		case connecting
		case connected
		/// Channel joined; `followers` is the number of PCs already present.
		case joined(followers: Int)
		case followerJoined
		case followerLeft
		case disconnected(reason: String, willRetry: Bool)
		case message(String)
		/// The PC pushed its clipboard.
		case clipboardReceived(String)
		/// A new line of braille cells from the PC.
		case braille(cells: [Int])
		/// The session stopped on its own and will not resume.
		case ended(reason: String)
		case untrustedCertificate(fingerprint: String)
	}

	public var onEvent: ((Event) -> Void)?
	/// Every line received, for debugging.
	public var onRawLine: ((String) -> Void)?

	private let info: ConnectionInfo
	private let transport: RelayTransport
	private let speech: SpeechOutput
	private let tones: TonePlayer
	private let sounds: SoundPlayer
	private var followers: Set<Int> = []
	/// Messages of the day already shown: as in NVDA, each is shown once, not on every reconnect.
	private var shownMessagesOfTheDay: Set<String> = []

	/// Muted: speech, beeps and sounds from the PC are ignored, like NVDA's
	/// "mute remote" option when working locally.
	public var isMuted = false {
		didSet {
			if isMuted { speech.cancel() }
		}
	}

	/// Sounds from the PC (browse mode, error, etc.) can be muted separately.
	public var playsRemoteSounds = true

	/// Width of the braille line the Mac shows, declared to the PC. 0 means no braille:
	/// the PC then never sends cells. Changing it tells the PC right away.
	public var brailleCellCount = 0 {
		didSet {
			if brailleCellCount != oldValue, !followers.isEmpty {
				sendBrailleInfo()
			}
		}
	}

	public init(
		info: ConnectionInfo,
		trustedFingerprint: String?,
		speech: SpeechOutput,
		tones: TonePlayer,
		sounds: SoundPlayer,
	) {
		self.info = info
		self.speech = speech
		self.tones = tones
		self.sounds = sounds
		transport = RelayTransport(info: info, trustedFingerprint: trustedFingerprint)
		transport.onEvent = { [weak self] event in self?.handle(event) }
		transport.onLine = { [weak self] line in self?.handle(line) }
	}

	public func start() {
		onEvent?(.connecting)
		transport.start()
	}

	/// Number of controllable PCs present on the channel.
	public var followerCount: Int { followers.count }

	/// Sends a key to the PC. Does nothing when not connected, as in NVDA.
	public func sendKey(_ key: WindowsKey, pressed: Bool) {
		transport.send(OutgoingMessage.key(key, pressed: pressed))
	}

	/// Sends text to the PC's clipboard.
	/// Sends a gesture from the Mac's braille display to NVDA.
	public func sendBraille(_ gesture: BrailleGesture) {
		transport.send(OutgoingMessage.brailleInput(gesture))
	}

	private func sendBrailleInfo() {
		transport.send(brailleCellCount > 0
			? OutgoingMessage.brailleInfo(name: "voiceOver", numCells: brailleCellCount)
			: OutgoingMessage.brailleInfo())
	}

	public func pushClipboard(_ text: String) {
		transport.send(OutgoingMessage.clipboardText(text))
	}

	public func stop() {
		transport.stop()
		speech.cancel()
		tones.stop()
		followers.removeAll()
	}

	// MARK: - Transport

	private func handle(_ event: RelayTransport.Event) {
		switch event {
		case .connected:
			transport.send(OutgoingMessage.protocolVersion())
			transport.send(OutgoingMessage.join(channel: info.key))
			speech.warmUp()
			onEvent?(.connected)
		case let .disconnected(reason, willRetry):
			followers.removeAll()
			speech.cancel()
			onEvent?(.disconnected(reason: reason, willRetry: willRetry))
		case let .untrustedCertificate(fingerprint):
			onEvent?(.untrustedCertificate(fingerprint: fingerprint))
		}
	}

	// MARK: - Messages

	private func handle(_ line: Data) {
		if let onRawLine {
			onRawLine(String(decoding: line, as: UTF8.self))
		}
		guard let message = try? IncomingMessage.parse(line) else { return }
		switch message {
		case let .speak(sequence, priority):
			guard !isMuted else { return }
			speech.speak(sequence, priority: priority)
		case .cancel:
			speech.cancel()
		case let .pauseSpeech(paused):
			speech.setPaused(paused)
		case let .tone(hz, milliseconds, left, right):
			guard !isMuted else { return }
			tones.beep(hz: hz, milliseconds: milliseconds, left: left, right: right)
		case let .channelJoined(clients):
			followers = Set(clients.filter(\.isFollower).map(\.id))
			if !followers.isEmpty {
				sendBrailleInfo()
			}
			onEvent?(.joined(followers: followers.count))
		case let .clientJoined(client) where client.isFollower:
			followers.insert(client.id)
			// The PC adjusts its braille on every arrival: repeat that we have none.
			sendBrailleInfo()
			onEvent?(.followerJoined)
		case let .clientLeft(client) where client.isFollower:
			if followers.remove(client.id) != nil {
				speech.cancel()
				onEvent?(.followerLeft)
			}
		case let .motd(text) where !text.isEmpty:
			if shownMessagesOfTheDay.insert(text).inserted {
				onEvent?(.message(text))
			}
		case .versionMismatch:
			end(localized("the server does not support protocol version \(currentProtocolVersion)"))
		case let .error(message):
			end(message == "incorrect_password" ? localized("incorrect key") : localized("server error: \(message)"))
		case .nvdaNotConnected:
			onEvent?(.message(localized("NVDA is not connected on the PC")))
		case let .wave(fileName):
			guard !isMuted, playsRemoteSounds else { return }
			sounds.playRemote(fileName: fileName)
		case let .display(cells):
			guard brailleCellCount > 0 else { return }
			onEvent?(.braille(cells: cells))
		case let .clipboardText(text):
			onEvent?(.clipboardReceived(text))
		case .clientJoined, .clientLeft, .motd, .ping, .other:
			break
		}
	}

	private func end(_ reason: String) {
		stop()
		onEvent?(.ended(reason: reason))
	}
}

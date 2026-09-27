import AVFoundation
import Foundation

/// Plays NVDA's sounds, bundled in `Sounds/` (GPL v2 or later, see LICENSE.md).
///
/// Two uses: sounds the PC requests (`wave`, for example switching to browse
/// mode), and the controller's own cues, taken from `_remoteClient/cues.py`.
@MainActor
public final class SoundPlayer {
	/// Cues played by the Mac itself, with the sounds NVDA associates with them.
	public enum Cue: String, Sendable {
		case connected
		case disconnected
		/// A controllable PC joined the channel.
		case controlling
		case clipboardPush
		case clipboardReceive
		case error
	}

	private var players: [String: AVAudioPlayer] = [:]

	public init() {}

	public func play(_ cue: Cue) {
		play(named: cue.rawValue)
	}

	/// Plays the sound requested by the PC. `fileName` is a Windows path, for example
	/// `C:\Program Files\NVDA\waves\browseMode.wav`: only the base name matters.
	/// An unknown sound, for example one from an add-on, is ignored.
	@discardableResult
	public func playRemote(fileName: String) -> Bool {
		guard let name = Self.soundName(fromRemotePath: fileName) else { return false }
		return play(named: name)
	}

	@discardableResult
	func play(named name: String) -> Bool {
		guard let player = player(named: name) else { return false }
		player.currentTime = 0
		return player.play()
	}

	private func player(named name: String) -> AVAudioPlayer? {
		if let player = players[name] {
			return player
		}
		guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
			let player = try? AVAudioPlayer(contentsOf: url)
		else { return nil }
		player.prepareToPlay()
		players[name] = player
		return player
	}

	/// Base name without extension, restricted to safe characters so it can never leave the folder.
	nonisolated static func soundName(fromRemotePath path: String) -> String? {
		let base = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
		let name = base.lowercased().hasSuffix(".wav") ? String(base.dropLast(4)) : base
		guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
		else { return nil }
		return name
	}
}

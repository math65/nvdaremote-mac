import AVFoundation

/// Joue les bips de NVDA (`tone`) : barre de progression, bascule de mode, etc.
///
/// Comme `tones.beep` dans NVDA, un nouveau bip coupe le précédent.
@MainActor
public final class TonePlayer {
	private static let sampleRate = 44_100.0
	/// Rampe d'entrée et de sortie, pour éviter les claquements.
	private static let fadeSeconds = 0.004
	/// Amplitude pour un volume de 100 sur un canal.
	private static let fullScaleAmplitude: Float = 0.6

	private let engine = AVAudioEngine()
	private let player = AVAudioPlayerNode()
	private let format = AVAudioFormat(standardFormatWithSampleRate: TonePlayer.sampleRate, channels: 2)!

	public init() {
		engine.attach(player)
		engine.connect(player, to: engine.mainMixerNode, format: format)
	}

	public func beep(hz: Double, milliseconds: Int, left: Int, right: Int) {
		guard hz > 0, milliseconds > 0,
			let buffer = makeBuffer(hz: hz, milliseconds: milliseconds, left: left, right: right)
		else { return }
		do {
			if !engine.isRunning {
				try engine.start()
			}
		} catch {
			return
		}
		player.stop()
		player.scheduleBuffer(buffer)
		player.play()
	}

	public func stop() {
		player.stop()
		engine.stop()
	}

	private func makeBuffer(hz: Double, milliseconds: Int, left: Int, right: Int) -> AVAudioPCMBuffer? {
		let frameCount = AVAudioFrameCount(Self.sampleRate * Double(milliseconds) / 1000)
		guard frameCount > 0,
			let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
			let channels = buffer.floatChannelData
		else { return nil }
		buffer.frameLength = frameCount

		let gains = [left, right].map { Float(min(max($0, 0), 100)) / 100 * Self.fullScaleAmplitude }
		let fadeFrames = max(1, min(Int(Self.sampleRate * Self.fadeSeconds), Int(frameCount) / 2))
		let step = 2 * Double.pi * hz / Self.sampleRate
		for frame in 0..<Int(frameCount) {
			let distanceToEdge = min(frame, Int(frameCount) - 1 - frame)
			let envelope = distanceToEdge < fadeFrames ? Float(distanceToEdge) / Float(fadeFrames) : 1
			let sample = Float(sin(step * Double(frame))) * envelope
			channels[0][frame] = sample * gains[0]
			channels[1][frame] = sample * gains[1]
		}
		return buffer
	}
}

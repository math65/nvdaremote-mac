import AVFoundation
import Foundation
import RemoteCore

let usage = """
	Usage:
	  nvdaremote <nvdaremote://… link>
	  nvdaremote --host <server> --key <key> [--port <port>]
	  nvdaremote --list-voices [language]

	Options:
	  --wpm <number>        speech rate in words per minute (default: 300)
	  --voice <name>        voice to use, by name or identifier
	  --trust <fingerprint> accept this certificate for this server and remember it
	  --verbose             print every message received from the PC

	Press Control+C to quit.
	"""

struct Options {
	var link: String?
	var host: String?
	var port = ConnectionInfo.defaultPort
	var key: String?
	var wordsPerMinute = 300
	var voice: String?
	var trust: String?
	var verbose = false
	var listVoices: String??
}

func fail(_ message: String, code: Int32 = 1) -> Never {
	FileHandle.standardError.write(Data((message + "\n").utf8))
	exit(code)
}

func parseOptions(_ arguments: [String]) -> Options {
	var options = Options()
	var iterator = arguments.makeIterator()
	func value(for flag: String) -> String {
		guard let value = iterator.next() else { fail("Missing value after \(flag).\n\n\(usage)") }
		return value
	}
	while let argument = iterator.next() {
		switch argument {
		case "-h", "--help":
			print(usage)
			exit(0)
		case "--host": options.host = value(for: argument)
		case "--key": options.key = value(for: argument)
		case "--port":
			guard let port = UInt16(value(for: argument)), port != 0 else { fail("Invalid port.") }
			options.port = port
		case "--wpm":
			guard let wpm = Int(value(for: argument)), (50...700).contains(wpm) else {
				fail("The rate must be between 50 and 700 words per minute.")
			}
			options.wordsPerMinute = wpm
		case "--voice": options.voice = value(for: argument)
		case "--trust": options.trust = value(for: argument)
		case "--verbose": options.verbose = true
		case "--list-voices":
			options.listVoices = .some(nil)
		default:
			if argument.hasPrefix("-") { fail("Unknown option: \(argument)\n\n\(usage)") }
			if case .some(nil) = options.listVoices {
				options.listVoices = .some(argument)
			} else {
				options.link = argument
			}
		}
	}
	return options
}

func listVoices(language: String?) {
	let voices = AVSpeechSynthesisVoice.speechVoices()
		.filter { language == nil || $0.language.lowercased().hasPrefix(language!.lowercased()) }
		.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
	for voice in voices {
		let quality = switch voice.quality {
		case .premium: "premium"
		case .enhanced: "enhanced"
		default: "standard"
		}
		print("\(voice.language)  \(voice.name), \(quality)  [\(voice.identifier)]")
	}
}

// Line-buffered status messages, even when redirected to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

if case let .some(language) = options.listVoices {
	listVoices(language: language)
	exit(0)
}

let info: ConnectionInfo
do {
	if let link = options.link {
		info = try ConnectionInfo(url: link)
	} else if let host = options.host, let key = options.key {
		info = ConnectionInfo(host: host, port: options.port, key: key)
	} else {
		fail(usage)
	}
} catch {
	fail(error.localizedDescription)
}

let trustStore = TrustStore()
if let trust = options.trust {
	do {
		try trustStore.trust(trust, for: info.address)
	} catch {
		fail("Unable to save the fingerprint: \(error.localizedDescription)")
	}
}

let speech = SpeechOutput(wordsPerMinute: options.wordsPerMinute, voice: options.voice)
if let voice = options.voice, SpeechOutput.findVoice(named: voice) == nil {
	print("Voice \"\(voice)\" not found, using \(speech.voiceDescription).")
}
let session = LeaderSession(
	info: info,
	trustedFingerprint: trustStore.fingerprint(for: info.address),
	speech: speech,
	tones: TonePlayer(),
	sounds: SoundPlayer(),
)

session.onEvent = { event in
	switch event {
	case .connecting:
		print("Connecting to \(info.address), voice \(speech.voiceDescription), \(options.wordsPerMinute) words per minute.")
	case .connected:
		print("Connected to the server.")
	case let .joined(followers):
		print(followers == 0 ? "Joined the channel. Waiting for the PC." : "Joined the channel. PC connected.")
	case .followerJoined:
		print("PC connected.")
	case .followerLeft:
		print("PC disconnected.")
	case let .disconnected(reason, willRetry):
		print("Disconnected: \(reason).\(willRetry ? " Retrying in 5 seconds." : "")")
	case let .message(text):
		print("Server message: \(text)")
	case .clipboardReceived:
		print("The PC sent its clipboard (ignored by this tool).")
	case .braille:
		break
	case let .ended(reason):
		fail("Stopped: \(reason).")
	case let .untrustedCertificate(fingerprint):
		fail("""
			The certificate of \(info.address) is not recognized.
			This is expected if the PC hosts the connection itself. Its fingerprint is:
			\(fingerprint)
			Check it on the PC, then run again with: --trust \(fingerprint)
			""", code: 2)
	}
}
if options.verbose {
	session.onRawLine = { print("← \($0)") }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
	MainActor.assumeIsolated {
		session.stop()
		print("\nGoodbye.")
		exit(0)
	}
}
interrupt.resume()

session.start()
RunLoop.main.run()

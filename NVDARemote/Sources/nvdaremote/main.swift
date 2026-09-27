import AVFoundation
import Foundation
import RemoteCore

let usage = """
	Utilisation :
	  nvdaremote <lien nvdaremote://…>
	  nvdaremote --host <serveur> --key <clé> [--port <port>]
	  nvdaremote --list-voices [langue]

	Options :
	  --wpm <nombre>        débit de parole en mots par minute (300 par défaut)
	  --voice <nom>         voix à utiliser, par nom ou identifiant
	  --trust <empreinte>   accepter ce certificat pour ce serveur et s'en souvenir
	  --verbose             afficher chaque message reçu du PC

	Contrôle+C pour quitter.
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
		guard let value = iterator.next() else { fail("Valeur manquante après \(flag).\n\n\(usage)") }
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
			guard let port = UInt16(value(for: argument)), port != 0 else { fail("Port invalide.") }
			options.port = port
		case "--wpm":
			guard let wpm = Int(value(for: argument)), (50...700).contains(wpm) else {
				fail("Le débit doit être compris entre 50 et 700 mots par minute.")
			}
			options.wordsPerMinute = wpm
		case "--voice": options.voice = value(for: argument)
		case "--trust": options.trust = value(for: argument)
		case "--verbose": options.verbose = true
		case "--list-voices":
			options.listVoices = .some(nil)
		default:
			if argument.hasPrefix("-") { fail("Option inconnue : \(argument)\n\n\(usage)") }
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
		case .enhanced: "améliorée"
		default: "standard"
		}
		print("\(voice.language)  \(voice.name), \(quality)  [\(voice.identifier)]")
	}
}

// Messages d'état ligne par ligne, même redirigés vers un fichier.
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
		fail("Impossible d'enregistrer l'empreinte : \(error.localizedDescription)")
	}
}

let speech = SpeechOutput(wordsPerMinute: options.wordsPerMinute, voice: options.voice)
if let voice = options.voice, SpeechOutput.findVoice(named: voice) == nil {
	print("Voix « \(voice) » introuvable, utilisation de \(speech.voiceDescription).")
}
let session = LeaderSession(
	info: info,
	trustedFingerprint: trustStore.fingerprint(for: info.address),
	speech: speech,
	tones: TonePlayer(),
)

session.onEvent = { event in
	switch event {
	case .connecting:
		print("Connexion à \(info.address), voix \(speech.voiceDescription), \(options.wordsPerMinute) mots par minute.")
	case .connected:
		print("Connecté au serveur.")
	case let .joined(followers):
		print(followers == 0 ? "Canal rejoint. En attente du PC." : "Canal rejoint. PC connecté.")
	case .followerJoined:
		print("PC connecté.")
	case .followerLeft:
		print("PC déconnecté.")
	case let .disconnected(reason, willRetry):
		print("Déconnecté : \(reason).\(willRetry ? " Nouvel essai dans 5 secondes." : "")")
	case let .message(text):
		print("Message du serveur : \(text)")
	case let .ended(reason):
		fail("Arrêt : \(reason).")
	case let .untrustedCertificate(fingerprint):
		fail("""
			Le certificat de \(info.address) n'est pas reconnu.
			C'est normal si le PC héberge lui-même la connexion. Son empreinte est :
			\(fingerprint)
			Vérifiez-la sur le PC, puis relancez avec : --trust \(fingerprint)
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
		print("\nAu revoir.")
		exit(0)
	}
}
interrupt.resume()

session.start()
RunLoop.main.run()

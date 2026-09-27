import Foundation

/// Remappe Verrouillage majuscules vers F18 avec `hidutil`, pour en faire une touche ordinaire.
///
/// Sans cela, avaler la touche dans le tap n'empêche pas le verrouillage de basculer
/// (docs/mesures-clavier.md). Le remappage retire Verr. maj. à tout le Mac : il n'est
/// donc appliqué que pendant le contrôle du PC.
///
/// `hidutil --set` remplace tous les remappages de l'utilisateur, et sous macOS 27
/// `--get` les affiche périphérique par périphérique. Plutôt que de risquer une fusion
/// approximative, on refuse d'agir si un remappage existe déjà. Un indicateur dans les
/// préférences permet de nettoyer au lancement suivant après un arrêt brutal.
public enum CapsLockRemap {
	static let capsLockUsage: Int64 = 0x7_0000_0039
	static let f18Usage: Int64 = 0x7_0000_006D
	private static let appliedKey = "capsLockRemapApplied"
	private static let hidutil = URL(filePath: "/usr/bin/hidutil")

	public static var isApplied: Bool {
		UserDefaults.standard.bool(forKey: appliedKey)
	}

	public static func apply() throws {
		guard !isApplied else { return }
		guard !hasMappings(try run(["property", "--get", "UserKeyMapping"])) else {
			throw CapsLockRemapError.existingMappings
		}
		UserDefaults.standard.set(true, forKey: appliedKey)
		let remap: [String: Int64] = [
			"HIDKeyboardModifierMappingSrc": capsLockUsage,
			"HIDKeyboardModifierMappingDst": f18Usage,
		]
		try setMapping([remap])
	}

	/// Retire le remappage. Sans effet si l'application ne l'a pas posé.
	public static func remove() throws {
		guard isApplied else { return }
		try setMapping([])
		UserDefaults.standard.removeObject(forKey: appliedKey)
	}

	/// Lit la sortie de `hidutil property --get UserKeyMapping`. Selon la version et l'historique,
	/// une absence de remappage s'affiche `(null)` ou en liste vide `( )`, sur une ou plusieurs
	/// lignes par périphérique : seule la présence d'une vraie règle compte.
	static func hasMappings(_ output: String) -> Bool {
		output.contains("HIDKeyboardModifierMappingSrc")
	}

	private static func setMapping(_ mapping: [[String: Int64]]) throws {
		let json = try JSONSerialization.data(withJSONObject: ["UserKeyMapping": mapping])
		_ = try run(["property", "--set", String(decoding: json, as: UTF8.self)])
	}

	private static func run(_ arguments: [String]) throws -> String {
		let process = Process()
		process.executableURL = hidutil
		process.arguments = arguments
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		let output = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CapsLockRemapError.hidutilFailed(String(decoding: output, as: UTF8.self))
		}
		return String(decoding: output, as: UTF8.self)
	}
}

public enum CapsLockRemapError: Error, LocalizedError {
	case existingMappings
	case hidutilFailed(String)

	public var errorDescription: String? {
		switch self {
		case .existingMappings:
			"Des remappages de touches existent déjà sur ce Mac. Pour ne pas les écraser, "
				+ "Verrouillage majuscules ne peut pas servir de touche NVDA : choisissez-en une autre."
		case let .hidutilFailed(output):
			"hidutil a échoué : \(output)"
		}
	}
}

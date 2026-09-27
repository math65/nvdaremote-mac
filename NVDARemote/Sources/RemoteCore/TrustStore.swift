import Foundation

/// Empreintes de certificats acceptées par l'utilisateur, par adresse `hôte:port`.
///
/// Équivalent de `trustedCertificates` dans la configuration de NVDA.
public struct TrustStore: Sendable {
	public let fileURL: URL

	public static var defaultFileURL: URL {
		URL.applicationSupportDirectory
			.appending(path: "NVDARemote", directoryHint: .isDirectory)
			.appending(path: "trusted-certificates.json")
	}

	public init(fileURL: URL = TrustStore.defaultFileURL) {
		self.fileURL = fileURL
	}

	public func fingerprint(for address: String) -> String? {
		load()[address]
	}

	public func trust(_ fingerprint: String, for address: String) throws {
		var entries = load()
		entries[address] = normalizeFingerprint(fingerprint)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true,
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(entries).write(to: fileURL, options: .atomic)
	}

	private func load() -> [String: String] {
		guard let data = try? Data(contentsOf: fileURL),
			let entries = try? JSONDecoder().decode([String: String].self, from: data)
		else { return [:] }
		return entries
	}
}

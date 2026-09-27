import Foundation

/// Certificate fingerprints accepted by the user, keyed by `host:port` address.
///
/// Equivalent of `trustedCertificates` in NVDA's configuration.
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
		// An unreadable file is kept aside rather than overwritten, so earlier
		// fingerprints are not silently lost.
		if entries.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) {
			let backup = fileURL.appendingPathExtension("unreadable")
			try? FileManager.default.removeItem(at: backup)
			try? FileManager.default.moveItem(at: fileURL, to: backup)
		}
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

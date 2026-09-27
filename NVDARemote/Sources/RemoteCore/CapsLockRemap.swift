import Foundation

/// Remaps Caps Lock to F18 with `hidutil`, turning it into an ordinary key.
///
/// Without this, swallowing the key in the event tap does not stop Caps Lock from toggling
/// (docs/keyboard-measurements.md). The remapping takes Caps Lock away from the whole Mac,
/// so it is only applied while controlling the PC.
///
/// `hidutil --set` replaces all of the user's remappings, and on macOS 27 `--get` lists
/// them device by device. Rather than risk an approximate merge, we refuse to act if a
/// remapping already exists. A flag in user defaults allows cleaning up on the next
/// launch after a crash.
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

	/// Removes the remapping. Does nothing if the app did not apply it.
	public static func remove() throws {
		guard isApplied else { return }
		try setMapping([])
		UserDefaults.standard.removeObject(forKey: appliedKey)
	}

	/// Parses the output of `hidutil property --get UserKeyMapping`. Depending on the version and history,
	/// no remapping shows up as `(null)` or as an empty list `( )`, on one or more lines
	/// per device: only the presence of an actual rule matters.
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
			localized(
				"Key remappings already exist on this Mac. To avoid overwriting them, Caps Lock cannot be used as the NVDA key: choose another one.",
			)
		case let .hidutilFailed(output):
			localized("hidutil failed: \(output)")
		}
	}
}

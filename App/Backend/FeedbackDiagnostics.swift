import AppKit
import RemoteCore

/// The technical snapshot attached to problem reports. The labels are not localized:
/// they end up in the developer's mail, not in the interface. Nothing identifying is
/// sent: no channel key, and no server address unless it is the public relay.
enum FeedbackDiagnostics {
	static func sections(for model: AppModel) -> [AppBackendClient.ReportSection] {
		let bundle = Bundle.main
		let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
		let server = model.server.trimmingCharacters(in: .whitespaces)
		let relay = server.isEmpty || server.hasPrefix(AppModel.publicServer)
			? AppModel.publicServer
			: "own server"

		func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

		return [
			.init(title: "Application", rows: [
				.init(label: "Version", value: AppBackendClient.appVersion),
				.init(label: "Build", value: build),
				.init(label: "Language", value: bundle.preferredLocalizations.first ?? "unknown"),
				.init(label: "VoiceOver running", value: yesNo(NSWorkspace.shared.isVoiceOverEnabled)),
			]),
			.init(title: "System", rows: [
				.init(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString),
				.init(label: "Processor", value: processorArchitecture),
			]),
			.init(title: "Connection", rows: [
				.init(label: "State", value: String(describing: model.phase)),
				.init(label: "Relay", value: relay),
				.init(label: "Controlling the PC", value: yesNo(model.isControllingPC)),
				.init(label: "Keyboard permissions", value: yesNo(model.hasKeyboardPermissions)),
			]),
			.init(title: "Braille", rows: [
				.init(label: "Enabled", value: yesNo(model.showsBraille)),
				.init(label: "Display", value: model.brailleDisplayName ?? "none"),
			]),
			.init(title: "Settings", rows: [
				.init(label: "Speech rate", value: "\(model.wordsPerMinute) wpm"),
				.init(label: "NVDA key", value: model.nvdaKey.rawValue),
				.init(label: "PC keyboard layout", value: model.pcLayout.rawValue),
				.init(label: "Mute on local control", value: yesNo(model.mutesOnLocalControl)),
				.init(label: "PC sounds", value: yesNo(model.playsRemoteSounds)),
				.init(label: "App sounds", value: yesNo(model.playsAppSounds)),
				.init(label: "Dock / menu bar", value: "\(yesNo(model.showsInDock)) / \(yesNo(model.showsInMenuBar))"),
			]),
		]
	}

	private static var processorArchitecture: String {
		#if arch(arm64)
			"Apple silicon"
		#else
			"Intel"
		#endif
	}
}

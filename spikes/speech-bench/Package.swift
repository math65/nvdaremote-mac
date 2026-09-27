// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "SpeechBench",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "SpeechBench",
			path: "Sources/SpeechBench",
			swiftSettings: [.swiftLanguageMode(.v5)],
		),
		.executableTarget(
			name: "StopDiag",
			path: "Sources/StopDiag",
			swiftSettings: [.swiftLanguageMode(.v5)],
		),
	],
)

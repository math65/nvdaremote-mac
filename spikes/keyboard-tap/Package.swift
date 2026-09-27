// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "KeyboardTap",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "KeyboardTap",
			path: "Sources/KeyboardTap",
			swiftSettings: [.swiftLanguageMode(.v5)],
		),
	],
)

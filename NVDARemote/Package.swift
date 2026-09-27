// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "NVDARemote",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "RemoteCore", targets: ["RemoteCore"]),
		.executable(name: "nvdaremote", targets: ["nvdaremote"]),
	],
	targets: [
		.target(name: "RemoteCore"),
		.executableTarget(
			name: "nvdaremote",
			dependencies: ["RemoteCore"],
		),
		.testTarget(
			name: "RemoteCoreTests",
			dependencies: ["RemoteCore"],
		),
	],
)

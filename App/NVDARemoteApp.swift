import AppKit
import SwiftUI

@main
struct NVDARemoteApp: App {
	@NSApplicationDelegateAdaptor private var delegate: AppDelegate
	@State private var model = AppModel()

	var body: some Scene {
		Window("NVDA Remote", id: "main") {
			ContentView()
				.environment(model)
		}
		.windowResizability(.contentSize)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}

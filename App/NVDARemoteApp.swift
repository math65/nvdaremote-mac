import AppKit
import SwiftUI

@main
struct NVDARemoteApp: App {
	static let connectionWindowID = "connection"

	@NSApplicationDelegateAdaptor private var delegate: AppDelegate
	@State private var model = AppModel()

	var body: some Scene {
		@Bindable var model = model

		Window("NVDA Remote", id: Self.connectionWindowID) {
			ConnectionView()
				.environment(model)
		}
		.windowResizability(.contentSize)
		.commands {
			// A single connection window: no New or Open commands.
			CommandGroup(replacing: .newItem) {}
			CommandMenu("Connection") {
				RemoteMenu(isMenuBarExtra: false)
					.environment(model)
			}
		}

		Settings {
			SettingsView()
				.environment(model)
		}

		MenuBarExtra(isInserted: $model.showsInMenuBar) {
			RemoteMenu(isMenuBarExtra: true)
				.environment(model)
		} label: {
			// Without an explicit label, VoiceOver reads the symbol's name ("keyboard").
			Image(systemName: model.isControllingPC ? "keyboard.fill" : "keyboard")
				.accessibilityLabel(Text("NVDA Remote"))
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationWillFinishLaunching(_ notification: Notification) {
		// Applied before the first window shows, so a Dock-less setup does not flash an icon.
		let showsInDock = UserDefaults.standard.object(forKey: AppModel.Keys.showsInDock) as? Bool ?? true
		NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
	}

	/// The app lives on in the menu bar when its window is closed.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}

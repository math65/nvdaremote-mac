import AppKit
import SwiftUI

@main
struct NVDARemoteApp: App {
	static let connectionWindowID = "connection"

	@NSApplicationDelegateAdaptor private var delegate: AppDelegate
	@State private var model = AppModel()
	@State private var updater = UpdaterModel()

	var body: some Scene {
		@Bindable var model = model

		Window("NVDA Remote", id: Self.connectionWindowID) {
			ConnectionView()
				.environment(model)
		}
		.windowResizability(.contentSize)
		.commands {
			CommandGroup(after: .appInfo) {
				Button("Check for Updates…", action: updater.checkForUpdates)
					.disabled(!updater.canCheckForUpdates)
			}
			// No help book: the help is the project's page, whose README is the manual.
			CommandGroup(replacing: .help) {
				Button("NVDA Remote Help") {
					NSWorkspace.shared.open(URL(string: "https://github.com/math65/nvdaremote-mac#readme")!)
				}
				ContactDeveloperButton()
			}
			// A single connection window: no New or Open commands.
			CommandGroup(replacing: .newItem) {}
			CommandMenu("Connection") {
				RemoteMenu(isMenuBarExtra: false)
					.environment(model)
					.environment(updater)
			}
		}

		Window("Contact the Developer", id: FeedbackView.windowID) {
			FeedbackView()
				.environment(model)
		}
		.windowResizability(.contentSize)

		Settings {
			SettingsView()
				.environment(model)
				.environment(updater)
		}

		MenuBarExtra(isInserted: $model.showsInMenuBar) {
			RemoteMenu(isMenuBarExtra: true)
				.environment(model)
				.environment(updater)
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

	func applicationDidFinishLaunching(_ notification: Notification) {
		Task { await AnnouncementCoordinator().checkAndPresent() }
	}

	/// The app lives on in the menu bar when its window is closed.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}

/// Opens the Contact the Developer window. Hidden when the build carries no backend
/// secret, since sending would always fail.
struct ContactDeveloperButton: View {
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		if AppBackendClient.isConfigured {
			Button("Contact the Developer…") {
				NSApp.activate()
				openWindow(id: FeedbackView.windowID)
			}
		}
	}
}

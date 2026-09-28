import AppKit
import RemoteCore
import SwiftUI

/// The app's commands, shared by the menu bar icon and the Connection menu of the
/// main menu, so both always offer the same thing.
struct RemoteMenu: View {
	/// The menu bar icon also carries Settings and Quit, which the main menu has elsewhere.
	var isMenuBarExtra: Bool

	@Environment(AppModel.self) private var model
	@Environment(UpdaterModel.self) private var updater
	@Environment(\.openWindow) private var openWindow
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		@Bindable var model = model
		if isMenuBarExtra {
			Text(model.status)
			Divider()
		}
		if model.isActive {
			Button("Disconnect", action: model.disconnect)
		} else {
			Button("Connect…", action: showConnectionWindow)
			if !model.recents.isEmpty {
				Menu("Recent Connections") {
					ForEach(model.recents) { recent in
						Button(recent.label) { model.connect(to: recent) }
					}
					Divider()
					Button("Clear Menu", action: model.forgetRecents)
				}
			}
		}
		Divider()
		Button(title(controlTitle, for: .toggleControl), action: model.toggleComputerControl)
			.keyboardShortcut(model.menuShortcut(for: .toggleControl))
			.disabled(!model.isComputerConnected)
		Button(title(String(localized: "Send Clipboard to PC"), for: .pushClipboard), action: model.pushClipboard)
			.keyboardShortcut(model.menuShortcut(for: .pushClipboard))
			.disabled(!model.isComputerConnected)
		Toggle("Mute the PC", isOn: $model.isMuted)
			.disabled(!model.isActive)

		if isMenuBarExtra {
			Divider()
			Button("Show Connection Window", action: showConnectionWindow)
			Button("Settings…") {
				NSApp.activate()
				openSettings()
			}
			Button("Check for Updates…", action: updater.checkForUpdates)
				.disabled(!updater.canCheckForUpdates)
			ContactDeveloperButton()
			Divider()
			Button("Quit NVDA Remote") { NSApp.terminate(nil) }
		}
	}

	private var controlTitle: String {
		model.isControllingPC
			? String(localized: "Control the Mac")
			: String(localized: "Control the PC")
	}

	/// Global shortcuts are handled by the keyboard capture; the menu shows them as key
	/// equivalents. A key that cannot be one (F1 to F12) is spelled out in the title.
	private func title(_ action: String, for command: GlobalCommand) -> String {
		model.menuShortcut(for: command) == nil
			? "\(action) (\(model.spokenShortcutName(for: command)))"
			: action
	}

	private func showConnectionWindow() {
		NSApp.activate()
		openWindow(id: NVDARemoteApp.connectionWindowID)
	}
}

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
		Button(controlTitle, action: model.toggleComputerControl)
			.disabled(!model.isComputerConnected)
		Button(clipboardTitle, action: model.pushClipboard)
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

	/// Global shortcuts are handled by the keyboard capture, not by the menu:
	/// they are only shown in the title, spelled out so VoiceOver reads them well.
	private var controlTitle: String {
		let action = model.isControllingPC
			? String(localized: "Control the Mac")
			: String(localized: "Control the PC")
		return "\(action) (\(model.spokenShortcutName(for: .toggleControl)))"
	}

	private var clipboardTitle: String {
		"\(GlobalCommand.pushClipboard.label) (\(model.spokenShortcutName(for: .pushClipboard)))"
	}

	private func showConnectionWindow() {
		NSApp.activate()
		openWindow(id: NVDARemoteApp.connectionWindowID)
	}
}

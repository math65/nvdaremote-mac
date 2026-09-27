import RemoteCore
import SwiftUI

/// The Settings window (Command-comma), one tab per topic.
struct SettingsView: View {
	var body: some View {
		TabView {
			GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
			SpeechSettings().tabItem { Label("Speech", systemImage: "waveform") }
			KeyboardSettings().tabItem { Label("Keyboard", systemImage: "keyboard") }
			SoundSettings().tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
			BrailleSettings().tabItem { Label("Braille", systemImage: "hand.point.up.braille") }
		}
		.frame(width: 480)
		.fixedSize(horizontal: false, vertical: true)
	}
}

private struct GeneralSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			// At least one of the two must stay visible, or the app could not be reached.
			Toggle("Show in the Dock", isOn: $model.showsInDock)
				.disabled(!model.showsInMenuBar)
				.accessibilityHint(Text("One of the two always stays visible. With the menu bar icon, the Dock icon only shows while the Connection window is open."))
			Toggle("Show in the menu bar", isOn: $model.showsInMenuBar)
				.disabled(!model.showsInDock)
				.accessibilityHint(Text("One of the two always stays visible."))
			Text("One of the two always stays visible. With the menu bar icon, the Dock icon only shows while the Connection window is open.")
				.font(.callout)
				.foregroundStyle(.secondary)
				// Already the control's hint: VoiceOver would read it twice.
				.accessibilityHidden(true)
		}
		.formStyle(.grouped)
	}
}

private struct SpeechSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			Slider(
				value: Binding(
					get: { Double(model.wordsPerMinute) },
					set: { model.wordsPerMinute = Int($0) },
				),
				in: 100...650,
				step: 25,
			) {
				Text("Rate")
			}
			.accessibilityValue(Text("\(model.wordsPerMinute) words per minute"))
			Text("\(model.wordsPerMinute) words per minute")
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			Toggle("Mute the PC when controlling the Mac", isOn: $model.mutesOnLocalControl)
				.accessibilityHint(Text("As in NVDA: the PC's speech and sounds stop while you work on the Mac."))
		}
		.formStyle(.grouped)
	}
}

private struct KeyboardSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			if !model.hasKeyboardPermissions {
				Section {
					Text("""
						To control the PC, the app must be able to capture the keyboard. \
						Allow it in System Settings, Privacy & Security, under both \
						Accessibility and Input Monitoring.
						""")
					Button("Request Permissions", action: model.requestKeyboardPermissions)
				}
			}
			Section("Shortcuts") {
				ForEach(GlobalCommand.allCases, id: \.self) { command in
					ShortcutRecorder(command: command)
				}
				Text("These shortcuts work from any app.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			Section("PC") {
				Picker("NVDA key", selection: $model.nvdaKey) {
					ForEach(NVDAKeyChoice.allCases, id: \.self) { choice in
						Text(choice.label).tag(choice)
					}
				}
				.accessibilityHint(model.nvdaKey == .capsLock
					? Text("While controlling the PC, Caps Lock becomes the NVDA key and no longer locks capitals on the Mac.")
					: Text("The Mac key that acts as NVDA's Insert key on the PC."))
				if model.nvdaKey == .capsLock {
					Text("While controlling the PC, Caps Lock becomes the NVDA key and no longer locks capitals on the Mac.")
						.font(.callout)
						.foregroundStyle(.secondary)
						// Already the control's hint: VoiceOver would read it twice.
						.accessibilityHidden(true)
				}
				Picker("PC keyboard layout", selection: $model.pcLayout) {
					ForEach(PCLayout.allCases, id: \.self) { layout in
						Text(layout.label).tag(layout)
					}
				}
				.accessibilityHint(Text("The layout set in Windows on the PC, used to type punctuation correctly."))
			}
		}
		.formStyle(.grouped)
	}
}

private struct SoundSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			Toggle("Play PC sounds", isOn: $model.playsRemoteSounds)
				.accessibilityHint(Text("Browse mode, focus mode, errors and other NVDA sounds."))
			Text("Browse mode, focus mode, errors and other NVDA sounds.")
				.font(.callout)
				.foregroundStyle(.secondary)
				// Already the control's hint: VoiceOver would read it twice.
				.accessibilityHidden(true)
			Toggle("Play app sounds", isOn: $model.playsAppSounds)
				.accessibilityHint(Text("Connection, clipboard, and switching between Mac and PC."))
			Text("Connection, clipboard, and switching between Mac and PC.")
				.font(.callout)
				.foregroundStyle(.secondary)
				// Already the control's hint: VoiceOver would read it twice.
				.accessibilityHidden(true)
		}
		.formStyle(.grouped)
	}
}

private struct BrailleSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			Toggle("Use the braille display for NVDA", isOn: $model.showsBraille)
				.accessibilityHint(Text("While you control the PC, NVDA drives your braille display: its line, routing keys, braille keyboard and panning keys. VoiceOver keeps running and gets the display back when you return to the Mac."))
			// Not a LabeledContent: inside a Form it exposes a frozen value to VoiceOver.
			Text("Braille display: \(model.brailleDisplayName ?? String(localized: "none found"))")
			Button("Look Again", action: model.lookForBrailleDisplay)
			Text("Works with HID braille displays, over USB or Bluetooth, such as the Brailliant BI X series. Displays that VoiceOver drives with a brand driver cannot be taken.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
		.formStyle(.grouped)
	}
}

import AppKit
import RemoteCore
import SwiftUI

/// A global shortcut's row: the command's name, then a button showing the shortcut
/// (⌃⌘R) that records a new one: press it, then type the combination, or Escape.
struct ShortcutRecorder: View {
	let command: GlobalCommand

	@Environment(AppModel.self) private var model
	@State private var monitor: Any?

	var body: some View {
		HStack {
			// VoiceOver gets the command's name in the button's label.
			Text(command.label)
				.accessibilityHidden(true)
			Spacer()
			Button(action: toggleRecording) {
				if monitor == nil {
					Text(verbatim: model.shortcutName(for: command))
						.monospacedDigit()
						.frame(minWidth: 60)
				} else {
					Text("Type the new shortcut, or Escape to cancel")
				}
			}
			.accessibilityLabel(monitor == nil
				? Text("\(command.label): \(model.spokenShortcutName(for: command))")
				: Text("Type the new shortcut, or Escape to cancel"))
			.accessibilityHint(Text("Works from any app. Press to record a new shortcut."))
		}
		.onDisappear(perform: stopRecording)
	}

	private func toggleRecording() {
		if monitor == nil {
			startRecording()
		} else {
			stopRecording()
			model.announce(String(localized: "Recording cancelled."))
		}
	}

	private func startRecording() {
		model.isRecordingShortcut = true
		model.announce(String(localized: "Type the new shortcut, or Escape to cancel."))
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			MainActor.assumeIsolated { record(event) }
			return nil
		}
	}

	private func record(_ event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let shortcut = KeyShortcut(
			keyCode: event.keyCode,
			control: flags.contains(.control),
			option: flags.contains(.option),
			command: flags.contains(.command),
			shift: flags.contains(.shift),
		)
		if event.keyCode == MacKeyCode.escape, !shortcut.isUsable {
			stopRecording()
			model.announce(String(localized: "Recording cancelled."))
			return
		}
		guard shortcut.isUsable else {
			model.announce(String(localized: "The shortcut must include Control or Option. Try again, or press Escape to cancel."))
			return
		}
		if let other = model.shortcuts.first(where: { $0.key != command && $0.value == shortcut })?.key {
			model.announce(String(localized: "This shortcut is already used for \(other.label). Try another one."))
			return
		}
		model.shortcuts[command] = shortcut
		stopRecording()
		model.announce(String(localized: "New shortcut: \(model.spokenShortcutName(for: command))."))
	}

	private func stopRecording() {
		if let monitor {
			NSEvent.removeMonitor(monitor)
		}
		monitor = nil
		model.isRecordingShortcut = false
	}
}

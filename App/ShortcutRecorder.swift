import AppKit
import RemoteCore
import SwiftUI

/// Bouton qui affiche le raccourci de bascule et en enregistre un nouveau :
/// on l'active, puis on tape la combinaison voulue, ou Échap pour annuler.
struct ShortcutRecorder: View {
	@Environment(AppModel.self) private var model
	@State private var monitor: Any?

	var body: some View {
		Button(action: toggleRecording) {
			if monitor == nil {
				Text("Raccourci de bascule : \(model.toggleShortcutName)")
			} else {
				Text("Tapez le nouveau raccourci, ou Échap pour annuler")
			}
		}
		.accessibilityHint("Active l'enregistrement d'un nouveau raccourci pour passer du Mac au PC.")
		.onDisappear(perform: stopRecording)
	}

	private func toggleRecording() {
		if monitor == nil {
			startRecording()
		} else {
			stopRecording()
			model.announce("Enregistrement annulé.")
		}
	}

	private func startRecording() {
		model.isRecordingShortcut = true
		model.announce("Tapez le nouveau raccourci, ou Échap pour annuler.")
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
			model.announce("Enregistrement annulé.")
			return
		}
		guard shortcut.isUsable else {
			model.announce("Le raccourci doit comporter Contrôle, Option ou Commande. Recommencez, ou Échap pour annuler.")
			return
		}
		model.toggleShortcut = shortcut
		stopRecording()
		model.announce("Nouveau raccourci de bascule : \(model.toggleShortcutName).")
	}

	private func stopRecording() {
		if let monitor {
			NSEvent.removeMonitor(monitor)
		}
		monitor = nil
		model.isRecordingShortcut = false
	}
}

import RemoteCore
import SwiftUI

/// The Connection window: server, key, status and recent connections. Nothing else:
/// settings live in their own window, commands in the menus.
struct ConnectionView: View {
	@Environment(AppModel.self) private var model
	@AppStorage("server") private var server = AppModel.publicServer
	@AppStorage("lastConnection") private var key = ""

	var body: some View {
		Form {
			Section {
				TextField("Server", text: $server, prompt: Text(verbatim: AppModel.publicServer))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
				TextField("Key", text: $key, prompt: Text("channel key, or nvdaremote:// link"))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
				Button(action: toggleConnection) {
					model.isActive ? Text("Disconnect") : Text("Connect")
				}
				.keyboardShortcut(.defaultAction)
				StatusRow(status: model.status)
			}
			if !model.recents.isEmpty, !model.isActive {
				Section("Recent Connections") {
					ForEach(model.recents) { recent in
						Button(recent.label) { use(recent) }
					}
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 420)
		.fixedSize(horizontal: false, vertical: true)
		.alert(
			"Unknown Certificate",
			isPresented: Binding(
				get: { model.pendingTrust != nil },
				set: { if !$0 { model.pendingTrust = nil } },
			),
			presenting: model.pendingTrust,
		) { pending in
			Button("Trust and Connect") { model.trust(pending) }
			Button("Cancel", role: .cancel) {}
		} message: { pending in
			Text("""
				The PC hosts the connection itself and presents its own certificate. \
				Only trust it if you are expecting this PC.

				Fingerprint: \(pending.fingerprint)
				""")
		}
	}

	private func toggleConnection() {
		if model.isActive {
			model.disconnect()
		} else if let info = model.connect(server: server, keyOrLink: key) {
			// A pasted link is split into both fields, which is what gets remembered.
			server = info.serverDescription
			key = info.key
		}
	}

	private func use(_ recent: RecentConnection) {
		server = recent.server
		key = recent.key
		model.connect(to: recent)
	}
}

/// The status line, as a single accessibility element.
///
/// Not a LabeledContent: inside a Form, it exposes a frozen copy of its value to
/// accessibility, and VoiceOver kept reading the initial status.
private struct StatusRow: View {
	let status: String

	var body: some View {
		HStack {
			Text("Status")
			Spacer()
			Text(status)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityAddTraits(.isStaticText)
		.accessibilityLabel(Text("Status"))
		.accessibilityValue(status)
	}
}

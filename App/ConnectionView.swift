import RemoteCore
import SwiftUI

/// The Connection window: server, key, status and recent connections. Nothing else:
/// settings live in their own window, commands in the menus.
struct ConnectionView: View {
	@Environment(AppModel.self) private var model
	@FocusState private var focusedField: Field?

	private enum Field {
		case server
		case key
	}

	var body: some View {
		@Bindable var model = model
		Form {
			Section("Connection") {
				TextField("Server", text: $model.server, prompt: Text(verbatim: AppModel.publicServer))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
					.focused($focusedField, equals: .server)
				TextField("Key", text: $model.key, prompt: Text("Channel key or nvdaremote:// link"))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
					.focused($focusedField, equals: .key)
				StatusRow(status: model.status)
				// The main action, at the bottom right as in any Mac form.
				HStack {
					Spacer()
					Button(action: toggleConnection) {
						model.isActive ? Text("Disconnect") : Text("Connect")
					}
					.keyboardShortcut(.defaultAction)
				}
			}
			if !model.recents.isEmpty, !model.isActive {
				Section("Recent Connections") {
					ForEach(model.recents) { recent in
						Button(recent.label) { model.connect(to: recent) }
					}
				}
			}
		}
		.formStyle(.grouped)
		.onAppear(perform: model.connectionWindowDidOpen)
		.onDisappear(perform: model.connectionWindowDidClose)
		// A clicked nvdaremote:// link, such as NVDA's "Copy link".
		.onOpenURL(perform: model.open)
		// The fields are disabled while connected, which takes focus away: give it back.
		.onChange(of: model.isActive) { _, isActive in
			if !isActive { focusedField = .key }
		}
		.frame(width: 420)
		.fixedSize(horizontal: false, vertical: true)
	}

	private func toggleConnection() {
		if model.isActive {
			model.disconnect()
		} else if !model.connect() {
			focusedField = Self.field(for: model.inputError)
		}
	}

	/// The field to fix for a given input error, so focus lands where the problem is.
	private static func field(for error: ConnectionInfoError?) -> Field {
		switch error {
		case .missingHost, .invalidPort: .server
		default: .key
		}
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
				.foregroundStyle(.readableSecondary)
				.multilineTextAlignment(.trailing)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityAddTraits(.isStaticText)
		.accessibilityLabel(Text("Status"))
		.accessibilityValue(status)
	}
}

import AppKit
import RemoteCore
import SwiftUI

/// The Connection window: server, key, status and recent connections. Nothing else:
/// settings live in their own window, commands in the menus.
struct ConnectionView: View {
	@Environment(AppModel.self) private var model
	@AppStorage("server") private var server = AppModel.publicServer
	@AppStorage("lastConnection") private var key = ""
	@FocusState private var focusedField: Field?

	private enum Field {
		case server
		case key
	}

	var body: some View {
		Form {
			Section("Connection") {
				TextField("Server", text: $server, prompt: Text(verbatim: AppModel.publicServer))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
					.focused($focusedField, equals: .server)
				TextField("Key", text: $key, prompt: Text("channel key, or nvdaremote:// link"))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
					.focused($focusedField, equals: .key)
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
		.onAppear(perform: model.connectionWindowDidOpen)
		.onDisappear(perform: model.connectionWindowDidClose)
		// A clicked nvdaremote:// link, such as NVDA's "Copy link", connects right away.
		.onOpenURL { url in
			NSApp.activate()
			connect(server: server, keyOrLink: url.absoluteString)
		}
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

				Fingerprint: \(Self.grouped(pending.fingerprint))
				""")
		}
	}

	private func toggleConnection() {
		if model.isActive {
			model.disconnect()
		} else {
			connect(server: server, keyOrLink: key)
		}
	}

	private func connect(server: String, keyOrLink: String) {
		if let info = model.connect(server: server, keyOrLink: keyOrLink) {
			// A link is split into both fields, which is what gets remembered.
			self.server = info.serverDescription
			key = info.key
		} else {
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

	/// A fingerprint in groups of four, easier to compare by ear or in braille.
	static func grouped(_ fingerprint: String) -> String {
		stride(from: 0, to: fingerprint.count, by: 4).map { start in
			let from = fingerprint.index(fingerprint.startIndex, offsetBy: start)
			let to = fingerprint.index(from, offsetBy: 4, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
			return String(fingerprint[from..<to])
		}.joined(separator: " ")
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

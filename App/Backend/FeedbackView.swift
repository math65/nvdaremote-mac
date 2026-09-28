import AppKit
import SwiftUI

/// The "Contact the Developer" window: a problem report (with a technical snapshot),
/// a suggestion or a question. Focus starts on the message type, sending and errors
/// are announced, and the window closes itself once the message is sent.
struct FeedbackView: View {
	static let windowID = "feedback"
	private static let emailKey = "appBackendFeedbackEmail"

	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss

	@State private var contactType = AppBackendClient.ContactType.bug
	@State private var email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
	@State private var message = ""
	@State private var isSending = false
	@State private var errorMessage: String?
	@FocusState private var typeFocused: Bool
	@AccessibilityFocusState private var errorFocused: Bool

	private let client = AppBackendClient()

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section {
					Picker("Message type", selection: $contactType) {
						ForEach(AppBackendClient.ContactType.allCases) { type in
							Text(type.title).tag(type)
						}
					}
					.focused($typeFocused)

					TextField("Your email address", text: $email)
						.textContentType(.emailAddress)
						.accessibilityHint(Text("The developer replies to this address."))
					HelpText("The developer replies to this address.")
				}

				Section {
					TextEditor(text: $message)
						.font(.body)
						.frame(height: 140)
						.accessibilityLabel(Text("Message"))
					if contactType == .bug {
						// Said nowhere else: VoiceOver reads it too.
						HelpText("Technical details are attached to help solve the problem: versions, settings and connection state. Never your channel key or your server address.", readByVoiceOver: true)
					}
				} header: {
					// The text area carries the same name for VoiceOver.
					Text("Message").accessibilityHidden(true)
				}

				if let errorMessage {
					Text(errorMessage)
						.foregroundStyle(.readableRed)
						.accessibilityFocused($errorFocused)
				}
			}
			.formStyle(.grouped)
			.scrollDisabled(true)

			HStack {
				if isSending {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text("Sending…"))
				}
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Send") { Task { await send() } }
					.keyboardShortcut(.defaultAction)
					.disabled(!canSend)
			}
			.padding([.horizontal, .bottom], 20)
		}
		.disabled(isSending)
		.frame(width: 480)
		.fixedSize(horizontal: false, vertical: true)
		.onAppear { typeFocused = true }
		.onChange(of: errorMessage) { _, newValue in
			if newValue != nil { errorFocused = true }
		}
	}

	private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
	private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

	/// A light check (text on both sides of an "@", a dot in the domain); the server
	/// does the real validation.
	private var emailLooksPlausible: Bool {
		let parts = trimmedEmail.split(separator: "@")
		return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && parts[1].contains(".")
	}

	private var canSend: Bool { !isSending && emailLooksPlausible && !trimmedMessage.isEmpty }

	/// A modal confirmation rather than a spoken message: VoiceOver reads it in full and
	/// the user decides when to move on.
	private func showConfirmation() {
		let alert = NSAlert()
		alert.messageText = String(localized: "Message sent")
		alert.informativeText = String(localized: "Thank you! The developer will reply to \(trimmedEmail).")
		alert.runModal()
	}

	private func send() async {
		guard canSend else { return }
		isSending = true
		errorMessage = nil
		defer { isSending = false }
		model.announce(String(localized: "Sending…"))
		do {
			if contactType == .bug {
				try await client.sendReport(
					email: trimmedEmail,
					summary: trimmedMessage,
					subjectHint: "Report from the app (v\(AppBackendClient.appVersion))",
					sections: FeedbackDiagnostics.sections(for: model),
				)
			} else {
				try await client.sendContact(email: trimmedEmail, type: contactType, message: trimmedMessage)
			}
			UserDefaults.standard.set(trimmedEmail, forKey: Self.emailKey)
			showConfirmation()
			dismiss()
		} catch {
			let message = ((error as? AppBackendClient.BackendError) ?? .server).localizedMessage
			errorMessage = message
			model.announce(message)
		}
	}
}

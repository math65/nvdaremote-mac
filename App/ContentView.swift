import RemoteCore
import SwiftUI

struct ContentView: View {
	@Environment(AppModel.self) private var model
	@AppStorage("server") private var server = AppModel.publicServer
	@AppStorage("lastConnection") private var key = ""

	var body: some View {
		@Bindable var model = model
		Form {
			Section {
				TextField("Serveur", text: $server, prompt: Text(AppModel.publicServer))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
				TextField("Clé", text: $key, prompt: Text("clé du canal, ou lien nvdaremote://"))
					.onSubmit(toggleConnection)
					.disabled(model.isActive)
				Button(model.isActive ? "Se déconnecter" : "Se connecter", action: toggleConnection)
					.keyboardShortcut(.defaultAction)
				// Pas de LabeledContent ici : dans un Form, il expose une copie figée
				// de sa valeur à l'accessibilité, et VoiceOver lisait toujours l'état initial.
				HStack {
					Text("État")
					Spacer()
					Text(model.status)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.trailing)
				}
				.accessibilityElement(children: .ignore)
				.accessibilityAddTraits(.isStaticText)
				.accessibilityLabel("État")
				.accessibilityValue(model.status)
				Button(
					model.isControllingPC ? "Revenir au Mac" : "Contrôler le PC",
					action: model.toggleComputerControl,
				)
				.disabled(model.phase != .connected)
			}
			Section("Clavier") {
				if !model.hasKeyboardPermissions {
					Text("""
						Pour piloter le PC, l'application doit pouvoir intercepter le clavier. \
						Autorisez-la dans Réglages Système, Confidentialité et sécurité, \
						à la fois dans Accessibilité et dans Surveillance de l'entrée.
						""")
					Button("Demander les autorisations", action: model.requestKeyboardPermissions)
				}
				ShortcutRecorder()
				Picker("Touche NVDA", selection: $model.nvdaKey) {
					ForEach(NVDAKeyChoice.allCases, id: \.self) { choice in
						Text(choice.label).tag(choice)
					}
				}
				if model.nvdaKey == .capsLock {
					Text("Pendant le contrôle du PC, Verrouillage majuscules devient la touche NVDA et ne verrouille plus les majuscules du Mac.")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				Picker("Disposition du clavier du PC", selection: $model.pcLayout) {
					ForEach(PCLayout.allCases, id: \.self) { layout in
						Text(layout.label).tag(layout)
					}
				}
			}
			Section("Parole") {
				Slider(
					value: Binding(
						get: { Double(model.wordsPerMinute) },
						set: { model.wordsPerMinute = Int($0) },
					),
					in: 100...650,
					step: 25,
				) {
					Text("Débit")
				}
				.accessibilityValue("\(model.wordsPerMinute) mots par minute")
				Text("\(model.wordsPerMinute) mots par minute")
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
		.fixedSize(horizontal: false, vertical: true)
		.alert(
			"Certificat inconnu",
			isPresented: Binding(
				get: { model.pendingTrust != nil },
				set: { if !$0 { model.pendingTrust = nil } },
			),
			presenting: model.pendingTrust,
		) { pending in
			Button("Faire confiance et se connecter") { model.trust(pending) }
			Button("Annuler", role: .cancel) {}
		} message: { pending in
			Text("""
				Le PC héberge lui-même la connexion et présente son propre certificat. \
				Ne faites confiance que si vous attendez bien ce PC.

				Empreinte : \(pending.fingerprint)
				""")
		}
	}

	private func toggleConnection() {
		if model.isActive {
			model.disconnect()
		} else if let info = model.connect(server: server, keyOrLink: key) {
			// Un lien collé est éclaté dans les deux champs, et c'est ce qui sera mémorisé.
			server = info.serverDescription
			key = info.key
		}
	}
}

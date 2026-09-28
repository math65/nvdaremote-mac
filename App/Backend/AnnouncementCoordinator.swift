import AppKit

/// Shows the message the developer may have published on the backend, once at launch.
/// The server always returns the active announcement; the "once" mode is applied here.
/// Network failures are silent: this must never get in the way of starting the app.
///
/// NSAlert rather than a SwiftUI alert: the app may have no window open (menu bar
/// only), and VoiceOver reads an NSAlert in full with native keyboard handling.
final class AnnouncementCoordinator {
	private enum Keys {
		static let installID = "appBackendInstallID"
		static let seenIDs = "appBackendSeenAnnouncementIDs"
	}

	private let client: AppBackendClient
	private let defaults: UserDefaults

	init(client: AppBackendClient = AppBackendClient(), defaults: UserDefaults = .standard) {
		self.client = client
		self.defaults = defaults
	}

	/// A random identifier for this installation, so the backend can count reach
	/// without knowing who anyone is.
	private var installID: String {
		if let id = defaults.string(forKey: Keys.installID) { return id }
		let id = UUID().uuidString
		defaults.set(id, forKey: Keys.installID)
		return id
	}

	private var seenIDs: [String] {
		get { defaults.stringArray(forKey: Keys.seenIDs) ?? [] }
		set { defaults.set(newValue, forKey: Keys.seenIDs) }
	}

	func checkAndPresent() async {
		guard AppBackendClient.isConfigured else { return }
		let language = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? "fr" : "en"
		guard let announcement = try? await client.checkAnnouncement(installID: installID, language: language),
			!(announcement.mode == "once" && seenIDs.contains(announcement.id))
		else { return }
		present(announcement)
	}

	private func present(_ announcement: AppBackendClient.Announcement) {
		let alert = NSAlert()
		alert.alertStyle = announcement.style == "warning" ? .warning : .informational
		alert.messageText = announcement.title
		alert.informativeText = announcement.body
		// With a link, OK stays the default button and the link comes second.
		// Without one, NSAlert shows its implicit OK.
		if let link = announcement.link {
			alert.addButton(withTitle: String(localized: "OK"))
			alert.addButton(withTitle: link.label)
		}
		NSApp.activate()
		let response = alert.runModal()

		if !seenIDs.contains(announcement.id) {
			seenIDs.append(announcement.id)
		}
		let installID = installID
		Task { await client.acknowledgeAnnouncement(installID: installID, announcementID: announcement.id) }

		if response == .alertSecondButtonReturn, let link = announcement.link, let url = Self.openableURL(for: link) {
			NSWorkspace.shared.open(url)
			Task { await client.reportAnnouncementClick(installID: installID, announcementID: announcement.id) }
		}
	}

	/// Only web links are opened: the response is remote input, and a `file:` URL or
	/// another app's scheme must not hide behind an innocent-looking button.
	static func openableURL(for link: AppBackendClient.Announcement.Link) -> URL? {
		guard let url = URL(string: link.url),
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https"
		else { return nil }
		return url
	}
}

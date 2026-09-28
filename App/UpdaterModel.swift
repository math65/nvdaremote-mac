import Combine
import Foundation
import Sparkle

/// Automatic and manual updates through Sparkle. The feed and the public signing key
/// are in `Config/Info.plist`; automatic checking is on by default there
/// (`SUEnableAutomaticChecks`), the runtime API below is only for the user's choices.
@Observable
final class UpdaterModel {
	nonisolated static let receivesBetaUpdatesKey = "receivesBetaUpdates"

	/// Sparkle is ready to start a check (false while one is running).
	private(set) var canCheckForUpdates = false

	@ObservationIgnored private let controller: SPUStandardUpdaterController
	/// Held strongly: Sparkle only keeps a weak reference to its delegate.
	@ObservationIgnored private let channelDelegate = ChannelDelegate()
	@ObservationIgnored private var canCheckObservation: AnyCancellable?

	init() {
		controller = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: channelDelegate,
			userDriverDelegate: nil,
		)
		canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
			.sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
		// Sparkle's scheduler checks at most once a day. This silent check on every
		// launch shows nothing unless a new version exists.
		if controller.updater.automaticallyChecksForUpdates {
			controller.updater.checkForUpdatesInBackground()
		}
	}

	/// Sparkle stores this choice in the app's defaults itself.
	var automaticallyChecksForUpdates: Bool {
		get {
			access(keyPath: \.automaticallyChecksForUpdates)
			return controller.updater.automaticallyChecksForUpdates
		}
		set {
			withMutation(keyPath: \.automaticallyChecksForUpdates) {
				controller.updater.automaticallyChecksForUpdates = newValue
			}
		}
	}

	/// Turning the beta channel on looks for a beta right away, silently, so the setting
	/// does not seem to do nothing for a day. Turning it off keeps the installed beta
	/// until a stable release overtakes it.
	var receivesBetaUpdates: Bool {
		get {
			access(keyPath: \.receivesBetaUpdates)
			return UserDefaults.standard.bool(forKey: Self.receivesBetaUpdatesKey)
		}
		set {
			withMutation(keyPath: \.receivesBetaUpdates) {
				UserDefaults.standard.set(newValue, forKey: Self.receivesBetaUpdatesKey)
			}
			if newValue { controller.updater.checkForUpdatesInBackground() }
		}
	}

	func checkForUpdates() {
		controller.updater.checkForUpdates()
	}
}

/// Opens the beta channel when the user asks for it. Sparkle asks on every check, so
/// the setting applies from the next one.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
	nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
		UserDefaults.standard.bool(forKey: UpdaterModel.receivesBetaUpdatesKey) ? ["beta"] : []
	}
}

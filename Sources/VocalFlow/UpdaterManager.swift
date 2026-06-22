import Foundation
import Combine
import Sparkle

/// Owns Sparkle's updater for the app.
///
/// Constructing the controller with `startingUpdater: true` starts the
/// scheduled background update checks configured by the `SU*` keys in
/// Info.plist (`SUFeedURL`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`).
/// Sparkle itself owns the "update available" UI, download, signature
/// verification, install and relaunch — this wrapper only exposes a manual
/// trigger and a couple of observable flags for the menu bar and Settings.
final class UpdaterManager: NSObject, ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so a menu item / button can
    /// disable itself while a check is already in flight.
    @Published var canCheckForUpdates = true

    /// User-facing toggle for automatic background checks. Sparkle persists the
    /// underlying value across launches.
    @Published var automaticChecksEnabled: Bool = true {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecksEnabled }
    }

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        // Seed from Sparkle's persisted value without re-triggering didSet's
        // write-back loop in a way that matters (the value is identical).
        automaticChecksEnabled = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated "Check for Updates…". Shows Sparkle's standard UI,
    /// including an "up to date" panel when there is nothing newer.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

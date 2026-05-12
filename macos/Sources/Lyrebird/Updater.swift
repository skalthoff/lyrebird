import Foundation
import Sparkle
import SwiftUI

/// Sparkle 2 auto-update glue.
///
/// ``Updater`` wraps ``SPUStandardUpdaterController`` so the rest of the
/// app can reach Sparkle through a single observable handle. The
/// controller reads `SUFeedURL` and `SUPublicEDKey` straight out of the
/// app's Info.plist — both are populated by the release workflow before
/// signing. In debug builds (Info.plist carries the `@@SPARKLE_PUBLIC_ED_KEY@@`
/// placeholder), Sparkle skips initialization so development launches
/// don't spam the console with signature errors.
///
/// The controller starts the scheduled update timer automatically when
/// `startingUpdater: true`; the SwiftUI `CheckForUpdatesView` below drives
/// the manual "Check for Updates…" menu item wired up in `LyrebirdApp`.
@MainActor
final class Updater: ObservableObject {
    /// `nil` in builds that ship without a real Sparkle public key — used
    /// by the UI layer to hide the "Check for Updates…" menu item when
    /// the app can't actually verify a feed.
    let controller: SPUStandardUpdaterController?

    /// Published mirror of `SPUUpdater.canCheckForUpdates` so SwiftUI
    /// views can disable the menu item while a check is already in
    /// flight. Sparkle exposes this via KVO on the underlying
    /// `SPUUpdater`; we forward it through `@Published`.
    @Published private(set) var canCheckForUpdates: Bool = false

    private var observer: NSKeyValueObservation?

    init() {
        // Skip Sparkle entirely when the public key hasn't been swapped
        // in (debug/local builds). The controller would otherwise fail
        // its signature-material check and log SUError.missingSigningKey
        // on every launch. See DISTRIBUTION.md for the build-time
        // substitution step.
        let plistKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let hasRealKey = plistKey != nil
            && plistKey?.isEmpty == false
            && plistKey != "@@SPARKLE_PUBLIC_ED_KEY@@"

        if hasRealKey {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.controller = controller

            // Seed the published value and subscribe for changes. KVO
            // fires on an arbitrary queue; MainActor hop ensures the
            // SwiftUI view tree only ever mutates on main.
            canCheckForUpdates = controller.updater.canCheckForUpdates
            observer = controller.updater.observe(
                \.canCheckForUpdates,
                options: [.new]
            ) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in
                    self?.canCheckForUpdates = value
                }
            }
        } else {
            self.controller = nil
            self.canCheckForUpdates = false
        }
    }

    /// Manual update-check entry point. Wired to the "Check for
    /// Updates…" menu command in `LyrebirdApp`. No-op when Sparkle is
    /// disabled (debug builds).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// SwiftUI helper that renders a menu item bound to the Sparkle
/// controller. Keep it isolated here so `LyrebirdApp` only has to pull in
/// one symbol.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}


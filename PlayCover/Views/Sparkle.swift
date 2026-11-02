//
//  Sparkle.swift
//  PlayCover
//
//  Created by Andrew Glaze on 7/17/22.
//  Copied from https://sparkle-project.org/documentation/programmatic-setup/
//

import Sparkle
import SwiftUI

// Fork builds must never install official releases: they replace the fork and drop its extra settings.
// A newer upstream release only tells the user to merge upstream into the fork and rebuild.
final class ForkUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let message = String(format: NSLocalizedString("updater.upstreamAvailable.message", comment: ""),
                             updateItem.displayVersionString, updateItem.versionString)
        // Sparkle reports the veto error itself only for user-initiated checks
        if updateCheck == .updatesInBackground {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("updater.upstreamAvailable.title", comment: "")
                alert.informativeText = message
                alert.runModal()
            }
        }
        throw NSError(domain: "io.playcover.PlayCover.fork", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// This view model class manages Sparkle's updater and publishes when new updates are allowed to be checked
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    // Strong reference: the updater controller only holds its delegate weakly
    private let updaterDelegate: ForkUpdaterDelegate

    @Published var canCheckForUpdates = false

    var automaticallyCheckForUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates
        }
        set(newValue) {
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    init() {
        // If you want to start the updater manually, pass false to startingUpdater and call .startUpdater() later
        // ForkUpdaterDelegate vetoes installing official releases
        updaterDelegate = ForkUpdaterDelegate()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil)

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if automaticallyCheckForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// This additional view is needed for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more information
struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button(NSLocalizedString("menubar.checkForUpdates", comment: ""),
               systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
               action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

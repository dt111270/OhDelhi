//
//  Updater.swift
//  OhDelhi
//
//  Sparkle auto-update glue. The updater runs automatically — silent
//  background download + install — driven by the Info.plist keys
//  (SUEnableAutomaticChecks = YES, SUAutomaticallyUpdate = YES,
//  SUScheduledCheckInterval). This file only adds the manual
//  "Check for Updates…" menu item, using Sparkle's recommended view-model
//  that disables the item while a check is already in flight.
//
//  Requires the Sparkle package (https://github.com/sparkle-project/Sparkle)
//  added via Swift Package Manager.
//

import SwiftUI
import Combine
import Sparkle

/// Tracks whether a manual update check is currently allowed, so the menu
/// item can grey itself out mid-check.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command. Automatic updates happen on their
/// own; this is just the manual trigger.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

//
//  OhDelhiApp.swift
//  OhDelhi
//
//  Entry point. Owns the `DeliveryStore` for the app's lifetime.
//

import SwiftUI
import Sparkle

@main
struct OhDelhiApp: App {
    @State private var store       = DeliveryStore()
    @State private var rmTracker   = RoyalMailTracker()
    @State private var amzTracker  = AmazonMailTracker()
    @State private var dhlTracker  = DHLTracker()
    @State private var fedexTracker = FedExTracker()
    @State private var parcelTracker = ParcelTracker()

    /// Sparkle. `startingUpdater: true` kicks off the background updater on
    /// launch; with the Info.plist auto-update keys set, it checks and installs
    /// new versions silently. Held for the app's lifetime.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(rmTracker)
                .environment(amzTracker)
                .environment(dhlTracker)
                .environment(fedexTracker)
                .environment(parcelTracker)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}  // suppress New Window
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Refresh Tracking") {
                    Task {
                        await rmTracker.refreshNow()
                        await amzTracker.refreshNow()
                        await dhlTracker.refreshNow()
                        await fedexTracker.refreshNow()
                        await parcelTracker.refreshNow()
                        store.reload()
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(rmTracker)
                .environment(amzTracker)
                .environment(dhlTracker)
                .environment(fedexTracker)
                .environment(parcelTracker)
                .frame(width: 580, height: 960)
        }
    }
}

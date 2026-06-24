//
//  OhDelhiMobileApp.swift
//  OhDelhiMobile
//
//  @main entry point. Owns a single iOSDeliveryStore, refreshes it on
//  app launch and whenever the app becomes active (returning from
//  background). No periodic polling — deliveries don't change
//  second-by-second and the iCloud snapshot is only rewritten by the
//  Mac when something actually changes.
//
//  Mirrors OmmediateMobileApp.
//

import SwiftUI

@main
struct OhDelhiMobileApp: App {

    @State private var store = iOSDeliveryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        store.load()
                    }
                }
        }
    }
}

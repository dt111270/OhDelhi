//
//  ContentView.swift
//  OhDelhi
//
//  Three-pane layout: sidebar (filters) | list (deliveries) | detail.
//

import SwiftUI

struct ContentView: View {
    @Environment(DeliveryStore.self) private var store

    @State private var selection: SidebarSelection? = .smart(.allExpected)
    @State private var selectedDelivery: Delivery? = nil

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            if let selection {
                DeliveryListView(
                    selection: selection,
                    selectedDelivery: $selectedDelivery
                )
                .navigationSplitViewColumnWidth(min: 360, ideal: 460)
            } else {
                ContentUnavailableView(
                    "Pick a filter",
                    systemImage: "shippingbox",
                    description: Text("Choose a smart filter or status from the sidebar.")
                )
            }
        } detail: {
            DeliveryDetailView(delivery: currentDelivery)
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        }
        .navigationTitle(selection?.displayName ?? "OhDelhi")
    }

    /// Re-resolve the selected delivery from the freshly-polled store so
    /// external edits in Obsidian (or our own writebacks) flow through within
    /// the polling interval, without losing the selection.
    private var currentDelivery: Delivery? {
        guard let stale = selectedDelivery else { return nil }
        return store.deliveries.first { $0.id == stale.id }
    }
}

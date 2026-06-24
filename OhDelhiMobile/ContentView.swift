//
//  ContentView.swift
//  OhDelhiMobile
//
//  Root view. A single list of in-flight deliveries (shipped /
//  out-for-delivery), soonest first. Tap a row → DeliveryActionSheet with
//  two actions: Track and Mark as Delivered.
//
//  The Mac is the source of truth; this view reads the iCloud snapshot on
//  launch, on foreground, and on manual reload / pull-to-refresh.
//

import SwiftUI

struct ContentView: View {

    @Environment(iOSDeliveryStore.self) private var store

    @State private var selected: DeliveryJSON?

    var body: some View {
        NavigationStack {
            Group {
                if store.inFlight.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Deliveries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload")
                }
            }
            .sheet(item: $selected) { delivery in
                DeliveryActionSheet(
                    delivery: delivery,
                    onDismiss: { selected = nil }
                )
            }
            .overlay(alignment: .bottom) {
                if let err = store.lastError {
                    Text(err)
                        .font(.footnote)
                        .padding(8)
                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private var list: some View {
        List(store.inFlight) { delivery in
            Button { selected = delivery } label: {
                DeliveryRowView(delivery: delivery)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .refreshable { store.load() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing in flight",
            systemImage: "shippingbox",
            description: Text("No parcels on the way right now. Open OhDelhi on the Mac to refresh the snapshot.")
        )
    }
}

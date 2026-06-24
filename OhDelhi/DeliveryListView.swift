//
//  DeliveryListView.swift
//  OhDelhi
//
//  Middle pane: list of deliveries matching the current sidebar selection.
//  Each row shows vendor • item • countdown chip (red for overdue/today,
//  orange for tomorrow, green for delivered, grey otherwise).
//

import SwiftUI

struct DeliveryListView: View {
    @Environment(DeliveryStore.self) private var store

    let selection: SidebarSelection
    @Binding var selectedDelivery: Delivery?

    var body: some View {
        List(selection: $selectedDelivery) {
            ForEach(items) { delivery in
                DeliveryRow(delivery: delivery)
                    .tag(delivery)
            }
        }
        .listStyle(.inset)
        .navigationTitle(selection.displayName)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "shippingbox",
                    description: Text("No deliveries match this filter.")
                )
            }
        }
    }

    private var items: [Delivery] {
        switch selection {
        case .smart(let f):   return store.deliveries(for: f)
        case .status(let s):  return store.deliveries(forStatus: s)
        }
    }
}

// MARK: - Row

private struct DeliveryRow: View {
    let delivery: Delivery

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CarrierBadge(delivery: delivery)
            VStack(alignment: .leading, spacing: 2) {
                Text(delivery.item)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(delivery.vendor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let carrier = delivery.carrier {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(carrier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            countdownChip
        }
        .padding(.vertical, 2)
    }

    private var countdownChip: some View {
        Text(delivery.countdownLabel)
            .font(.caption)
            .fontWeight(.medium)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                delivery.countdownTint.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(delivery.countdownTint)
    }
}

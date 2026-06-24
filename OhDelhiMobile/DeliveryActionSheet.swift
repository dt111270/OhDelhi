//
//  DeliveryActionSheet.swift
//  OhDelhiMobile
//
//  Modal sheet shown when a delivery row is tapped. Identity block at the
//  top, then exactly two actions:
//
//    • Track       — opens the parcel's tracking URL in Safari (only shown
//                    when the note has a tracking_url).
//    • Mark as Delivered — fires one Advanced URI flipping status to
//                    delivered; the Mac does the rest.
//
//  Deliberately minimal. Anything else (editing, email, status nuance) is
//  Mac-only work.
//

import SwiftUI
import UIKit

struct DeliveryActionSheet: View {

    @Environment(iOSDeliveryStore.self) private var store

    let delivery: DeliveryJSON
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            identity
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            Text(delivery.vendor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(delivery.item)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                if let carrier = delivery.carrier, !carrier.isEmpty {
                    Text(carrier)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                Text(delivery.countdownLabel())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(delivery.countdownUrgency().color)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            if let urlString = delivery.trackingURL,
               let url = URL(string: urlString) {
                Button {
                    Task {
                        onDismiss()        // dismiss first; the open runs on the next turn
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Track", systemImage: "shippingbox.and.arrow.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button {
                Task {
                    onDismiss()        // dismiss first; the Advanced URI open runs on the next turn
                    store.markAsDelivered(delivery)
                }
            } label: {
                Label("Mark as Delivered", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)

            Button("Cancel", role: .cancel, action: onDismiss)
                .controlSize(.large)
        }
    }
}

//
//  DeliveryRowView.swift
//  OhDelhiMobile
//
//  One row in the deliveries list: vendor + item on top, carrier underneath,
//  a countdown chip trailing. The countdown is computed on-device (relative
//  to "now") so it stays correct as the snapshot ages.
//

import SwiftUI

struct DeliveryRowView: View {

    let delivery: DeliveryJSON

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(delivery.vendor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(delivery.item)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let carrier = delivery.carrier, !carrier.isEmpty {
                    Text(carrier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            countdownChip
        }
        .padding(.vertical, 4)
    }

    private var countdownChip: some View {
        let urgency = delivery.countdownUrgency()
        return Text(delivery.countdownLabel())
            .font(.caption.weight(.semibold))
            .foregroundStyle(urgency.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(urgency.color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

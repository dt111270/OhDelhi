//
//  UrgencyColor.swift
//  OhDelhiMobile
//
//  Maps the Foundation-only `DeliveryJSON.CountdownUrgency` to a SwiftUI
//  Color. Kept out of the shared snapshot file so that file stays
//  UI-agnostic. Matches the Mac's `Delivery.countdownTint` palette.
//

import SwiftUI

extension DeliveryJSON.CountdownUrgency {
    var color: Color {
        switch self {
        case .overdue:  .red
        case .today:    .red
        case .tomorrow: .orange
        case .soon:     .secondary
        case .none:     .secondary
        }
    }
}

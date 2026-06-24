//
//  DeliverySnapshot.swift
//  OhDelhi
//
//  Wire format for the iCloud delivery snapshot — the bridge between the
//  Mac app and OhDelhiMobile.
//
//  Deliberately narrow. The Mac's DeliveryStore snapshots ONLY the parcels
//  worth acting on from a phone: status `order-confirmed`, `shipped`, or
//  `out-for-delivery`. The earlier pipeline (reservation / pre-order) and
//  everything terminal (delivered / never-arrived) is Mac-only — the phone
//  is intentionally not a place to do that admin.
//
//  This file is shared between the OhDelhi (Mac) and OhDelhiMobile (iOS)
//  targets via Xcode synchronised-folder membership exceptions — identical
//  struct definitions on both sides keep the encode/decode in lockstep.
//
//  Foundation-only on purpose: it compiles unchanged into the Mac app and
//  the iOS app. No SwiftUI here — colour mapping lives in the iOS views,
//  driven by `countdownUrgency`.
//

import Foundation

// MARK: - DeliveryJSON

/// JSON representation of a single in-flight delivery for the iCloud
/// snapshot. Only the handful of fields the phone needs. New fields should
/// be added as `Optional` so older snapshots keep decoding.
struct DeliveryJSON: Codable, Hashable, Identifiable {

    /// Vault-relative path to the underlying `.md` file — both the row
    /// identity in SwiftUI lists and the `filepath` argument for the
    /// Advanced URI writeback.
    let id: String

    let vendor: String
    let item: String

    /// Raw `DeliveryStatus.rawValue` — in practice `"order-confirmed"`,
    /// `"shipped"`, or `"out-for-delivery"`, but kept free-form so a new
    /// status doesn't force a schema bump.
    let status: String

    let carrier: String?

    /// Track Parcel opens this in Safari.
    let trackingURL: String?

    /// The parcel's tracking reference. Surfaced so the phone's Edit sheet can
    /// pre-fill it. Optional — older snapshots without it still decode (nil).
    let trackingNumber: String?

    let expectedDelivery: Date?
    let confirmedDelivery: Date?
}

// MARK: - On-device derived helpers

extension DeliveryJSON {

    /// Authoritative delivery date: `confirmedDelivery` if set (the carrier's
    /// best current guess), otherwise `expectedDelivery`. Mirrors the Mac
    /// `Delivery.targetDate`.
    var targetDate: Date? { confirmedDelivery ?? expectedDelivery }

    /// Sort key. Missing dates sort last rather than crashing the sort.
    var sortDate: Date { targetDate ?? .distantFuture }

    /// Whole-day difference from `now` to `targetDate` (positive = future,
    /// 0 = today, negative = overdue). `nil` if no target date.
    func daysUntilTarget(asOf now: Date = Date()) -> Int? {
        guard let when = targetDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let target = cal.startOfDay(for: when)
        return cal.dateComponents([.day], from: today, to: target).day
    }

    /// Visual urgency bucket. The iOS view maps this to a colour so this
    /// Foundation-only model stays UI-agnostic.
    enum CountdownUrgency {
        case overdue
        case today
        case tomorrow
        case soon
        case none
    }

    func countdownUrgency(asOf now: Date = Date()) -> CountdownUrgency {
        guard let d = daysUntilTarget(asOf: now) else { return .none }
        if d < 0  { return .overdue }
        if d == 0 { return .today }
        if d == 1 { return .tomorrow }
        return .soon
    }

    /// Text for the countdown chip, computed relative to `now` so it stays
    /// correct as the snapshot ages on the device.
    func countdownLabel(asOf now: Date = Date()) -> String {
        guard let d = daysUntilTarget(asOf: now) else { return "—" }
        switch d {
        case ..<(-1): return "\(-d) days late"
        case -1:      return "1 day late"
        case 0:       return "Today"
        case 1:       return "Tomorrow"
        default:      return "in \(d) days"
        }
    }
}

// MARK: - DeliveriesPayload

/// Top-level payload written to `Documents/deliveries.json` in the iCloud
/// container.
struct DeliveriesPayload: Codable {

    /// Bump when `DeliveryJSON`'s shape changes incompatibly so the iOS side
    /// can detect and reject stale snapshots gracefully.
    static let currentSchema: Int = 1

    let schema: Int
    let writtenAt: Date
    let deliveries: [DeliveryJSON]

    init(deliveries: [DeliveryJSON], writtenAt: Date = Date()) {
        self.schema = Self.currentSchema
        self.writtenAt = writtenAt
        self.deliveries = deliveries
    }
}

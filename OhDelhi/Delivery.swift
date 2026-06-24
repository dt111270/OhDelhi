//
//  Delivery.swift
//  OhDelhi
//
//  The Delivery model. One per `.md` file in `03.10 Deliveries/`.
//  `id = fileURL` so list selection survives reloads (Oatly pattern).
//

import Foundation
import SwiftUI

// MARK: - Status

/// Workflow states for a delivery. Order = pipeline order (earliest → latest).
/// The `4-delivery-report` skill writes these values; the app reads them.
enum DeliveryStatus: String, Hashable, CaseIterable, Identifiable {
    case reservation
    case preOrder       = "pre-order"
    case orderConfirmed = "order-confirmed"
    case shipped
    case outForDelivery = "out-for-delivery"
    case delivered
    case neverArrived   = "never-arrived"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .reservation:    "Reservation"
        case .preOrder:       "Pre-Order"
        case .orderConfirmed: "Order Confirmed"
        case .shipped:        "Shipped"
        case .outForDelivery: "Out for Delivery"
        case .delivered:      "Delivered"
        case .neverArrived:   "Never Arrived"
        }
    }

    /// SF Symbol shown alongside the status in the sidebar.
    var systemImage: String {
        switch self {
        case .reservation:    "calendar.badge.clock"
        case .preOrder:       "bookmark"
        case .orderConfirmed: "doc.text"
        case .shipped:        "shippingbox"
        case .outForDelivery: "truck.box"
        case .delivered:      "checkmark.circle.fill"
        case .neverArrived:   "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .reservation:    .secondary
        case .preOrder:       .secondary
        case .orderConfirmed: .blue
        case .shipped:        .indigo
        case .outForDelivery: .orange
        case .delivered:      .green
        case .neverArrived:   .gray
        }
    }

    /// True for any non-terminal status. Drives the All Expected catch-all
    /// filter and all the time-based predicates (`isDueToday`, `isOverdue`,
    /// `isThisWeek`, etc.). Terminal states (delivered, never-arrived) sit
    /// outside the active workflow and only surface via their own sidebar
    /// Status row.
    var isExpected: Bool {
        switch self {
        case .delivered, .neverArrived: return false
        default:                        return true
        }
    }

    /// Sort order: earliest pipeline step first; terminal states at the
    /// bottom. Used to order the sidebar status section consistently and
    /// to gate the forward-only `forwardStatus` helper — never-arrived is
    /// ranked highest so once set it's sticky against any automatic flip.
    var pipelineRank: Int {
        switch self {
        case .reservation:    0
        case .preOrder:       1
        case .orderConfirmed: 2
        case .shipped:        3
        case .outForDelivery: 4
        case .delivered:      5
        case .neverArrived:   6
        }
    }
}

// MARK: - Smart filters

/// Time-based / state-based smart filters that pivot the list view on top of
/// the raw status values. The same parcel can appear in multiple smart filters
/// (e.g. shipped + arriving today).
enum SmartFilter: String, Hashable, CaseIterable, Identifiable {
    case today
    case tomorrow
    case thisWeek
    case overdue
    case allExpected
    case recentlyDelivered

    var id: Self { self }

    var displayName: String {
        switch self {
        case .today:             "Today"
        case .tomorrow:          "Tomorrow"
        case .thisWeek:          "This Week"
        case .overdue:           "Overdue"
        case .allExpected:       "All Expected"
        case .recentlyDelivered: "Recently Delivered"
        }
    }

    var systemImage: String {
        switch self {
        case .today:             "flame"
        case .tomorrow:          "sun.horizon"
        case .thisWeek:          "calendar"
        case .overdue:           "exclamationmark.triangle"
        case .allExpected:       "shippingbox"
        case .recentlyDelivered: "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .today:             .red
        case .tomorrow:          .orange
        case .thisWeek:          .blue
        case .overdue:           .red
        case .allExpected:       .indigo
        case .recentlyDelivered: .green
        }
    }
}

// MARK: - Delivery

struct Delivery: Identifiable, Hashable {
    // Identity
    let fileURL: URL
    var id: URL { fileURL }

    // Core metadata
    var vendor: String
    var item: String
    var orderNumber: String?
    var orderDate: Date?
    var status: DeliveryStatus
    var carrier: String?
    var trackingNumber: String?
    var trackingURLString: String?
    var expectedDelivery: Date?
    var expectedDeliveryFrom: Date?
    var confirmedDelivery: Date?
    var total: Double?
    var currency: String?
    var quantity: Int?
    var emailURLString: String?

    /// Amazon item identifier (10-char `B0...`). Lets multi-item Amazon
    /// orders pair their status-update emails to the right per-item note
    /// without relying on the truncated visible item name.
    var asin: String?

    /// Amazon shipment identifier (from the OFD/Dispatched tracking URL,
    /// `shipmentId=...`). Stamped on a note when its first status-update
    /// email arrives; helps traceability when items in one order ship in
    /// multiple parcels.
    var shipmentId: String?

    /// Transient instruction written by OhDelhiMobile's Edit sheet via a single
    /// Advanced URI (iOS can only fire one URI per action). A `;;`-delimited
    /// list of `key=value` pairs (keys: `carrier`, `expected`, `tracking`).
    /// `DeliveryStore` applies each to the real frontmatter field, then removes
    /// this line. Never persisted long-term.
    var mobileEdit: String?

    /// Body content after the closing `---` fence. Plain markdown.
    var body: String

    // ---- Derived helpers ---------------------------------------------------

    var trackingURL: URL? {
        guard let s = trackingURLString, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var emailURL: URL? {
        guard let s = emailURLString, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Authoritative delivery date: `confirmedDelivery` if set (the tracking
    /// shortcut's best guess), otherwise `expectedDelivery`. Used both for
    /// sorting and for the countdown display, so a parcel "expected 4 Jun"
    /// with a tracking-confirmed date of "2 Jun" sorts and counts to 2 Jun.
    var targetDate: Date? {
        confirmedDelivery ?? expectedDelivery
    }

    /// Date used for store-level sorting. Falls back to `orderDate` so that
    /// the rare note missing both expected and confirmed still has a sortable
    /// key (otherwise it would land in the distant future).
    var sortDate: Date? {
        targetDate ?? orderDate
    }

    /// Whole-day difference from today against `targetDate` (positive = future,
    /// negative = past, 0 = today). Returns `nil` if neither confirmed nor
    /// expected is set.
    var daysUntilTarget: Int? {
        guard let when = targetDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: when)
        return cal.dateComponents([.day], from: today, to: target).day
    }

    var isOverdue: Bool {
        guard status.isExpected, let d = daysUntilTarget else { return false }
        return d < 0
    }

    /// Today *or* overdue. Overdue parcels deserve more attention, not less,
    /// so they re-enter the "things I should care about now" buckets even
    /// though they also have their own Overdue filter.
    var isDueToday: Bool {
        guard status.isExpected, let d = daysUntilTarget else { return false }
        return d <= 0
    }

    /// Specifically tomorrow — a forward-looking slot. Overdue parcels don't
    /// belong here; they belong in Today (action needed now).
    var isDueTomorrow: Bool {
        guard status.isExpected, let d = daysUntilTarget else { return false }
        return d == 1
    }

    /// Everything from "still overdue" through "next six days". The same
    /// reasoning as Today — late parcels stay in the imminent bucket.
    var isThisWeek: Bool {
        guard status.isExpected, let d = daysUntilTarget else { return false }
        return d <= 6
    }

    /// Display string for the countdown chip on the row.
    var countdownLabel: String {
        switch status {
        case .delivered:    return "Delivered"
        case .neverArrived: return "Never arrived"
        default: break
        }
        guard let d = daysUntilTarget else {
            return "—"
        }
        switch d {
        case ..<(-1): return "\(-d) days late"
        case -1:      return "1 day late"
        case 0:       return "Today"
        case 1:       return "Tomorrow"
        default:      return "in \(d) days"
        }
    }

    /// Colour for the countdown chip — red for overdue/today, green for
    /// delivered, gray for never-arrived, secondary for everything else.
    var countdownTint: Color {
        switch status {
        case .delivered:    return .green
        case .neverArrived: return .gray
        default: break
        }
        guard let d = daysUntilTarget else { return .secondary }
        if d < 0  { return .red }
        if d == 0 { return .red }
        if d == 1 { return .orange }
        return .secondary
    }

    /// Range string if the expected delivery is a window, e.g. "1–4 Jun".
    /// Otherwise the singular expected date, or nil.
    var expectedDeliveryDisplay: String? {
        guard let to = expectedDelivery else { return nil }
        let cal = Calendar.current
        if let from = expectedDeliveryFrom, !cal.isDate(from, inSameDayAs: to) {
            return "\(Self.shortDate(from))–\(Self.shortDate(to))"
        }
        return Self.shortDate(to)
    }

    var orderDateDisplay: String? {
        orderDate.map(Self.shortDate)
    }

    var confirmedDeliveryDisplay: String? {
        confirmedDelivery.map(Self.shortDate)
    }

    var totalDisplay: String? {
        guard let t = total else { return nil }
        let cur = currency ?? "GBP"
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = cur
        nf.locale = Locale(identifier: "en_GB")
        return nf.string(from: NSNumber(value: t)) ?? "\(cur) \(t)"
    }

    // ---- Formatting helpers ------------------------------------------------

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    private static func shortDate(_ d: Date) -> String {
        shortFormatter.string(from: d)
    }
}

// MARK: - Snapshot bridge

extension Delivery {
    /// Map into the narrow `DeliveryJSON` wire format for the OhDelhiMobile
    /// iCloud snapshot. `vaultRelativePath` is the path Obsidian Advanced URI
    /// wants for `filepath=` (relative to the vault root).
    func toJSON(vaultRelativePath: String) -> DeliveryJSON {
        DeliveryJSON(
            id:                vaultRelativePath,
            vendor:            vendor,
            item:              item,
            status:            status.rawValue,
            carrier:           carrier,
            trackingURL:       trackingURLString,
            trackingNumber:    trackingNumber,
            expectedDelivery:  expectedDelivery,
            confirmedDelivery: confirmedDelivery
        )
    }
}

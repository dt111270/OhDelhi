//
//  CarrierBadge.swift
//  OhDelhi
//
//  Small square graphic for the left of each delivery row.
//
//  Resolution order:
//   1. If a `carrier:` field is set, use the carrier's identity.
//   2. Otherwise fall back to the vendor's identity (Amazon Logistics being
//      implicit, eBay shipping its own way, etc.).
//   3. Otherwise a generic package badge.
//
//  Each identity has an `assetName` looked up in `Assets.xcassets`. If the
//  asset exists, the badge renders the real logo. If not, it falls back to
//  an initials chip in the identity's tint colour. Drop a 256×256 transparent
//  PNG (or SVG) into `Assets.xcassets/<asset-name>.imageset/` — the carrier
//  image sets live at the TOP LEVEL of the catalog (e.g. `amazon`, `dhl`,
//  `fedex`, `royal-mail`, `evri`), not in a sub-group — and it takes over
//  without any code change.
//

import SwiftUI
import AppKit

// MARK: - Identity

struct BadgeIdentity {
    /// Asset-catalog name to look up first (e.g. `"royal-mail"`).
    let assetName: String

    /// 1–3 character initials shown when no asset is found.
    let initials: String

    /// Background tint for the fallback chip; also the tint applied to the
    /// asset image's brand colour echo in a thin ring (currently unused, kept
    /// for future bordered styling).
    let tint: Color
}

enum CarrierResolver {

    /// Resolve the badge identity for a delivery. Carrier first, vendor as
    /// proxy second, generic last.
    static func identity(for delivery: Delivery) -> BadgeIdentity {
        if let carrier = delivery.carrier, !carrier.isEmpty {
            return carrierIdentity(carrier)
        }
        return vendorIdentity(delivery.vendor)
    }

    // MARK: Carrier table

    /// Known carriers seen in `03.10 Deliveries/` (May 2026 audit). New carrier
    /// strings will pass through to the generic-from-name fallback at the
    /// bottom — add an explicit row here when one starts appearing often.
    private static let carriers: [String: BadgeIdentity] = [
        "royal mail":   BadgeIdentity(assetName: "royal-mail",
                                      initials: "RM",
                                      tint: Color(red: 0.85, green: 0.14, blue: 0.13)),
        "fedex":        BadgeIdentity(assetName: "fedex",
                                      initials: "FX",
                                      tint: Color(red: 0.30, green: 0.08, blue: 0.55)),
        "yodel":        BadgeIdentity(assetName: "yodel",
                                      initials: "YO",
                                      tint: Color(red: 0.66, green: 0.13, blue: 0.55)),
        "yun express":  BadgeIdentity(assetName: "yun-express",
                                      initials: "YE",
                                      tint: Color(red: 0.95, green: 0.42, blue: 0.08)),
        "dhl express":  BadgeIdentity(assetName: "dhl",
                                      initials: "DHL",
                                      tint: Color(red: 0.99, green: 0.80, blue: 0.00)),
        "dhl":          BadgeIdentity(assetName: "dhl",
                                      initials: "DHL",
                                      tint: Color(red: 0.99, green: 0.80, blue: 0.00)),
    ]

    private static func carrierIdentity(_ carrier: String) -> BadgeIdentity {
        let key = carrier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = carriers[key] { return known }
        return BadgeIdentity(
            assetName: key.replacingOccurrences(of: " ", with: "-"),
            initials: initialsFromName(carrier),
            tint: stableColor(for: carrier)
        )
    }

    // MARK: Vendor proxy table

    /// When `carrier:` is missing, fall back to the vendor's shipping
    /// identity. Amazon parcels are most often Amazon Logistics anyway; eBay
    /// orders use a mix but the eBay branding still reads cleanly.
    private static let vendors: [String: BadgeIdentity] = [
        "amazon": BadgeIdentity(assetName: "amazon",
                                initials: "AMZ",
                                tint: Color(red: 1.0,  green: 0.60, blue: 0.0)),
        "ebay":   BadgeIdentity(assetName: "ebay",
                                initials: "eB",
                                tint: Color(red: 0.90, green: 0.20, blue: 0.22)),
    ]

    private static func vendorIdentity(_ vendor: String) -> BadgeIdentity {
        let key = vendor.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = vendors[key] { return known }
        return BadgeIdentity(
            assetName: key.replacingOccurrences(of: " ", with: "-"),
            initials: initialsFromName(vendor),
            tint: stableColor(for: vendor)
        )
    }

    // MARK: Fallback helpers

    /// Up to 3 characters of "initials" from a free-form name. Honours word
    /// boundaries (e.g. "Norma Design" → "ND", "WashiWednesday" → "WA").
    private static func initialsFromName(_ name: String) -> String {
        let words = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.prefix(2)
                .compactMap { $0.first.map(Character.init) }
                .map { String($0).uppercased() }
                .joined()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// Deterministic colour from a name. Same input always gets the same
    /// hue, so unknown vendors keep a stable identity across reloads.
    private static func stableColor(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.70)
    }
}

// MARK: - View

struct CarrierBadge: View {
    let delivery: Delivery
    var side: CGFloat = 36

    var body: some View {
        let identity = CarrierResolver.identity(for: delivery)
        return Group {
            if let nsImage = NSImage(named: identity.assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .frame(width: side, height: side)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(identity.tint)
                    Text(identity.initials)
                        .font(.system(size: side * 0.32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                }
                .frame(width: side, height: side)
            }
        }
        .accessibilityLabel(delivery.carrier ?? delivery.vendor)
    }
}

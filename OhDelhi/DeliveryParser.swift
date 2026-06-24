//
//  DeliveryParser.swift
//  OhDelhi
//
//  Parses a `.md` file with YAML frontmatter into a `Delivery`.
//  Tolerant of Yams' Date-vs-String duality.
//

import Foundation
import Yams

enum DeliveryParser {

    static func parse(fileURL: URL) -> Delivery? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let (yamlBlock, body) = splitFrontmatter(from: text) else { return nil }

        do {
            guard let dict = try Yams.load(yaml: yamlBlock) as? [String: Any] else { return nil }
            guard let vendor = stringValue(dict["vendor"]), !vendor.isEmpty else { return nil }
            guard let item   = stringValue(dict["item"]),   !item.isEmpty   else { return nil }

            let statusString = stringValue(dict["status"]) ?? ""
            let status = DeliveryStatus(rawValue: statusString) ?? .orderConfirmed

            return Delivery(
                fileURL:              fileURL,
                vendor:               vendor,
                item:                 item,
                orderNumber:          stringValue(dict["order_number"]),
                orderDate:            dateValue(dict["order_date"]),
                status:               status,
                carrier:              stringValue(dict["carrier"]),
                trackingNumber:       stringValue(dict["tracking_number"]),
                trackingURLString:    stringValue(dict["tracking_url"]),
                expectedDelivery:     dateValue(dict["expected_delivery"]),
                expectedDeliveryFrom: dateValue(dict["expected_delivery_from"]),
                confirmedDelivery:    dateValue(dict["confirmed_delivery"]),
                total:                doubleValue(dict["total"]),
                currency:             stringValue(dict["currency"]),
                quantity:             intValue(dict["quantity"]),
                emailURLString:       stringValue(dict["email_url"]),
                asin:                 stringValue(dict["asin"]),
                shipmentId:           stringValue(dict["shipment_id"]),
                mobileEdit:           stringValue(dict["mobile_edit"]),
                body:                 body
            )
        } catch {
            return nil
        }
    }

    // MARK: - Frontmatter split

    /// Splits the file at the YAML frontmatter. Returns the YAML block (without
    /// the `---` fences) and the body after the closing fence (trimmed of one
    /// leading newline).
    private static func splitFrontmatter(from text: String) -> (String, String)? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterFirstFence = text.dropFirst(4)
        guard let endRange = afterFirstFence.range(of: "\n---") else { return nil }
        let yamlBlock = String(afterFirstFence[..<endRange.lowerBound])
        var bodyStart = endRange.upperBound
        // Skip the newline directly after the closing `---`, if any, so the
        // body string doesn't start with a blank line.
        if bodyStart < afterFirstFence.endIndex,
           afterFirstFence[bodyStart] == "\n" {
            bodyStart = afterFirstFence.index(after: bodyStart)
        }
        let body = String(afterFirstFence[bodyStart...])
        return (yamlBlock, body)
    }

    // MARK: - Value coercion

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = .current   // local timezone — delivery dates are calendar dates, not UTC
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            return s.isEmpty ? nil : s
        // Unquoted YAML dates come back as Foundation Date — re-format to ISO.
        case let d as Date:
            return isoDateFormatter.string(from: d)
        case let n as Int:
            return String(n)
        case let d as Double:
            return String(d)
        default:
            return nil
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int:    return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default:              return nil
        }
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let n as Int:    return Double(n)
        case let s as String: return Double(s)
        default:              return nil
        }
    }

    private static func dateValue(_ any: Any?) -> Date? {
        switch any {
        case let d as Date:   return d
        case let s as String:
            guard !s.isEmpty else { return nil }
            // Allow YYYY-MM-DD strings (Yams typically returns Date for those,
            // but be tolerant of quoted variants).
            if let d = isoDateFormatter.date(from: s) { return d }
            return nil
        default: return nil
        }
    }
}

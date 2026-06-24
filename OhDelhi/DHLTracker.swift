//
//  DHLTracker.swift
//  OhDelhi
//
//  Third tracking provider: hits DHL's "Shipment Tracking - Unified" REST API
//  for each non-delivered delivery whose carrier looks like DHL, and writes
//  the returned `estimatedTimeOfDelivery` to the note's `confirmed_delivery`
//  frontmatter field.
//
//  Endpoint:
//    GET https://api-eu.dhl.com/track/shipments?trackingNumber=<NUMBER>
//    Header: DHL-API-Key: <KEY>
//
//  Key source: `~/.config/dhl/credentials.json` with shape
//    { "api_key": "..." }
//
//  Cadence: hourly (free tier is rate-limited to ~250 calls/day; hourly with
//  a handful of in-flight parcels stays comfortably under). User can hit
//  ⇧⌘T or the Refresh now button in Settings for an immediate scan.
//

import Foundation
import Observation

@Observable
final class DHLTracker {

    // ---- Public state ------------------------------------------------------

    private(set) var isRunning: Bool = false
    private(set) var lastScan: Date? = nil
    private(set) var lastStatus: String = "Never run"
    private(set) var lastError: String? = nil
    private(set) var recentUpdates: [TrackingUpdate] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            restartTimer()
        }
    }

    // ---- Init --------------------------------------------------------------

    private static let enabledKey = "OhDelhi.dhlTracker.enabled"
    private static let interval: TimeInterval = 60 * 60   // 1 hour

    private var timer: Timer?

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshNow() }
        }
    }

    // ---- Public API --------------------------------------------------------

    @MainActor
    func refreshNow() async {
        if isRunning { return }
        isRunning = true
        defer { isRunning = false }

        guard let apiKey = loadAPIKey() else {
            lastError = "Missing or invalid ~/.config/dhl/credentials.json (need {\"api_key\": \"…\"})"
            lastStatus = "Not configured"
            return
        }

        do {
            let deliveries = try loadDeliveries()
            let candidates = deliveries.filter(isDHL)

            var fresh: [TrackingUpdate] = []
            var apiErrors = 0
            var checked  = 0

            for d in candidates {
                guard let tn = d.trackingNumber, !tn.isEmpty else { continue }
                checked += 1
                do {
                    let parsed = try await fetchEstimate(for: tn, apiKey: apiKey)
                    guard let date = parsed.date else { continue }

                    // Skip if already correct.
                    if let existing = d.confirmedDelivery,
                       Calendar.current.isDate(existing, inSameDayAs: date) {
                        continue
                    }

                    try NoteEditor.setField(
                        "confirmed_delivery",
                        to: Self.iso(date),
                        in: d.fileURL
                    )

                    fresh.append(TrackingUpdate(
                        fileURL: d.fileURL,
                        item: d.item,
                        previousConfirmedDelivery: d.confirmedDelivery,
                        newConfirmedDelivery: date,
                        source: "DHL API",
                        timestamp: Date()
                    ))
                } catch {
                    apiErrors += 1
                    // Don't bail the whole scan on a single API failure —
                    // could be a transient 5xx or a 404 for an unknown TN.
                    if apiErrors == 1 {
                        lastError = "DHL API: \(error.localizedDescription)"
                    }
                }
            }

            recentUpdates = (fresh + recentUpdates).prefix(20).map { $0 }
            lastScan = Date()

            var bits: [String] = ["Checked \(checked) parcel\(checked == 1 ? "" : "s")"]
            if fresh.isEmpty {
                bits.append("no new dates")
            } else {
                bits.append("\(fresh.count) updated")
            }
            if apiErrors > 0 {
                bits.append("\(apiErrors) API error\(apiErrors == 1 ? "" : "s")")
            }
            lastStatus = bits.joined(separator: " · ")
            if apiErrors == 0 { lastError = nil }
        } catch {
            lastError = error.localizedDescription
            lastStatus = "Scan failed"
        }
    }

    // ---- Filtering ---------------------------------------------------------

    /// DHL parcels: carrier field contains "DHL" (case-insensitive) and the
    /// parcel isn't already delivered. We don't try to match by tracking-
    /// number format because DHL numbers overlap with other carriers' formats
    /// — the explicit carrier label is more reliable.
    private func isDHL(_ d: Delivery) -> Bool {
        guard d.status != .delivered else { return false }
        guard let c = d.carrier?.lowercased() else { return false }
        return c.contains("dhl")
    }

    // ---- API client --------------------------------------------------------

    private struct DHLResponse: Decodable {
        let shipments: [DHLShipment]?
    }

    private struct DHLShipment: Decodable {
        let status: DHLStatus?
        let estimatedTimeOfDelivery: String?
    }

    private struct DHLStatus: Decodable {
        let timestamp: String?
        let statusCode: String?
        let status: String?
        let description: String?
    }

    private struct ParsedShipment {
        let date: Date?
        let statusCode: String?
    }

    private func fetchEstimate(for trackingNumber: String, apiKey: String) async throws -> ParsedShipment {
        var components = URLComponents(string: "https://api-eu.dhl.com/track/shipments")!
        components.queryItems = [URLQueryItem(name: "trackingNumber", value: trackingNumber)]
        guard let url = components.url else {
            throw NSError(domain: "DHLTracker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "DHL-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DHLTracker", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw NSError(domain: "DHLTracker", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Auth rejected — check API key"])
        case 404:
            // No shipment for this tracking number — nothing wrong, just no data.
            return ParsedShipment(date: nil, statusCode: nil)
        case 429:
            throw NSError(domain: "DHLTracker", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited — backing off"])
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DHLTracker",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(body.prefix(120))"]
            )
        }

        let decoded = try JSONDecoder().decode(DHLResponse.self, from: data)
        let shipment = decoded.shipments?.first

        // Prefer estimatedTimeOfDelivery (in-transit forecast). Fall back to
        // the status timestamp when the shipment is already delivered — that
        // gives us the actual delivery date to stamp.
        if let est = shipment?.estimatedTimeOfDelivery, let d = Self.parseDate(est) {
            return ParsedShipment(date: d, statusCode: shipment?.status?.statusCode)
        }
        if shipment?.status?.statusCode?.lowercased() == "delivered",
           let ts = shipment?.status?.timestamp,
           let d = Self.parseDate(ts) {
            return ParsedShipment(date: d, statusCode: shipment?.status?.statusCode)
        }
        return ParsedShipment(date: nil, statusCode: shipment?.status?.statusCode)
    }

    // ---- Credentials --------------------------------------------------------

    private struct Credentials: Decodable {
        let api_key: String
    }

    private func loadAPIKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dhl/credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let creds = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        let trimmed = creds.api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "PASTE_KEY_HERE" ? nil : trimmed
    }

    // ---- Deliveries loading ------------------------------------------------

    private func loadDeliveries() throws -> [Delivery] {
        let folder = UserDefaults.standard.string(forKey: "OhDelhi.deliveriesFolder")
            ?? Self.defaultDeliveriesFolder
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { DeliveryParser.parse(fileURL: $0) }
    }

    private static var defaultDeliveriesFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DTObs/00-09 DTOS/03 Working Folders/03.10 Deliveries")
            .path(percentEncoded: false)
    }

    // ---- Formatters --------------------------------------------------------

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    /// DHL returns dates as ISO8601 strings — either `"2026-05-25"` (date only)
    /// or `"2026-05-25T12:00:00"` (datetime). We only care about the day, so
    /// chop to the first 10 characters and parse as `YYYY-MM-DD`.
    private static func parseDate(_ s: String) -> Date? {
        let prefix = String(s.prefix(10))
        return isoFormatter.date(from: prefix)
    }
}

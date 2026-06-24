//
//  ParcelTracker.swift
//  OhDelhi
//
//  Read-only tracking provider backed by the Parcel app (parcelapp.net).
//  A single GET returns all of David's active Parcel deliveries; we match each
//  to existing notes and write the carrier's expected date + status in. Parcel
//  does the per-carrier polling we'd otherwise have to build ourselves.
//
//  Endpoint:
//    GET https://api.parcel.app/external/deliveries/?filter_mode=active
//    Header: api-key: <KEY>
//
//  Key source: ~/.config/parcel/credentials.json  { "api_key": "..." }
//
//  Matching:
//   - Amazon (carrier_code begins "amz"): Parcel's `tracking_number` IS the
//     Amazon order number. Group entries by order; if the order's entries
//     agree on status + expected day, apply to EVERY note for that order — so
//     an item Parcel doesn't separately name but which rides in the same
//     parcel (e.g. a soy sauce bundled with a recipe book) still gets updated.
//     If the order's shipments genuinely disagree, fall back to matching each
//     entry to a note by `description` prefix.
//   - Everything else: join on `tracking_number`, fan out to all matches.
//
//  Writes (read-only — never creates notes):
//   - date_expected -> confirmed_delivery (date only; matches DHL/RM trackers).
//   - status_code -> status, forward-only (pipelineRank gate):
//       2 in transit       -> shipped
//       4 out for delivery  -> out-for-delivery
//       0 delivered         -> date only; status flip stays MANUAL (preserves
//                              the false-"delivered" refund handle).
//       others (1/3/5/6/7/8)-> date only.
//
//  Cadence: hourly (limit is 20 req/hour; one call per scan). ⇧⌘T or the
//  Refresh button trigger an immediate scan.
//

import Foundation
import Observation

@Observable
final class ParcelTracker {

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

    private static let enabledKey = "OhDelhi.parcelTracker.enabled"
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
            lastError = "Missing or invalid ~/.config/parcel/credentials.json (need {\"api_key\": \"…\"})"
            lastStatus = "Not configured"
            return
        }

        do {
            let parcels = try await fetchDeliveries(apiKey: apiKey)
            let notes   = try loadDeliveries()
            let apps    = Self.computeApplications(parcels: parcels, notes: notes)

            var fresh: [TrackingUpdate] = []
            var dateWrites   = 0
            var statusWrites = 0
            var clearWrites  = 0

            for app in apps {
                let d = app.note

                // Status — forward-only, and never auto-flips to delivered.
                if let newStatus = Self.status(for: app.statusCode),
                   newStatus.pipelineRank > d.status.pipelineRank {
                    try? NoteEditor.setField("status", to: newStatus.rawValue, in: d.fileURL)
                    statusWrites += 1
                }

                // Date — confirmed_delivery, only when it actually changes.
                if let date = app.date {
                    let already = d.confirmedDelivery.map {
                        Calendar.current.isDate($0, inSameDayAs: date)
                    } ?? false
                    if !already {
                        try? NoteEditor.setField("confirmed_delivery", to: Self.iso(date), in: d.fileURL)
                        fresh.append(TrackingUpdate(
                            fileURL: d.fileURL,
                            item: d.item,
                            previousConfirmedDelivery: d.confirmedDelivery,
                            newConfirmedDelivery: date,
                            source: "Parcel",
                            timestamp: Date()
                        ))
                        dateWrites += 1
                    }
                } else if app.statusCode == Self.preShipmentCode, d.confirmedDelivery != nil {
                    // Parcel is tracking this parcel as pre-shipment (the carrier
                    // doesn't physically have it yet) AND has no ETA — so any
                    // confirmed_delivery in the note is premature. Clear it. This
                    // self-heals stale dates (e.g. a FedEx "due by" that was
                    // attributed before the parcel was actually collected).
                    try? NoteEditor.setField("confirmed_delivery", to: nil, in: d.fileURL)
                    clearWrites += 1
                }
            }

            recentUpdates = (fresh + recentUpdates).prefix(20).map { $0 }
            lastScan = Date()

            var bits: [String] = ["\(parcels.count) in Parcel", "\(apps.count) matched"]
            if dateWrites > 0   { bits.append("\(dateWrites) date\(dateWrites == 1 ? "" : "s")") }
            if statusWrites > 0 { bits.append("\(statusWrites) status") }
            if clearWrites > 0  { bits.append("\(clearWrites) cleared") }
            if dateWrites == 0 && statusWrites == 0 && clearWrites == 0 { bits.append("no changes") }
            lastStatus = bits.joined(separator: " · ")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lastStatus = "Scan failed"
        }
    }

    // ---- Matching ----------------------------------------------------------

    struct Application {
        let note: Delivery
        let statusCode: Int
        let date: Date?
    }

    /// Pure matcher (no I/O) so it can be reasoned about and unit-tested.
    static func computeApplications(parcels: [ParcelDelivery], notes: [Delivery]) -> [Application] {
        var out: [Application] = []

        let isAmazon: (ParcelDelivery) -> Bool = { $0.carrier_code.lowercased().hasPrefix("amz") }

        // Non-Amazon: join on the real carrier tracking number.
        for p in parcels where !isAmazon(p) {
            let tn = p.tracking_number.trimmingCharacters(in: .whitespaces)
            guard !tn.isEmpty else { continue }
            for note in notes where (note.trackingNumber ?? "").caseInsensitiveCompare(tn) == .orderedSame {
                out.append(Application(note: note, statusCode: p.status_code, date: parseDate(p.date_expected)))
            }
        }

        // Amazon: Parcel's tracking_number is the order number.
        let byOrder = Dictionary(grouping: parcels.filter(isAmazon), by: { $0.tracking_number })
        for (orderNumber, group) in byOrder {
            let orderNotes = notes.filter { $0.orderNumber == orderNumber }
            guard !orderNotes.isEmpty else { continue }

            // Uniform if every entry agrees on (status, expected day).
            let distinct = Set(group.map { "\($0.status_code)|\(dateKey($0.date_expected))" })
            if distinct.count <= 1, let rep = group.first {
                for note in orderNotes {
                    out.append(Application(note: note, statusCode: rep.status_code, date: parseDate(rep.date_expected)))
                }
            } else {
                // Genuine split shipment — be precise: each entry -> its item.
                for entry in group {
                    for note in orderNotes where descriptionMatches(entry.description, note.item) {
                        out.append(Application(note: note, statusCode: entry.status_code, date: parseDate(entry.date_expected)))
                    }
                }
            }
        }

        return out
    }

    /// Match an item label for prefix comparison, in whichever direction is
    /// shorter — Parcel truncates its `description`, and OhDelhi sometimes
    /// truncates `item` too, so we compare on the common prefix.
    static func descriptionMatches(_ parcelDescription: String?, _ noteItem: String) -> Bool {
        guard let p = parcelDescription else { return false }
        let a = normalize(p)
        let b = normalize(noteItem)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["…", "..."] {
            while t.hasSuffix(suffix) {
                t.removeLast(suffix.count)
                t = t.trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    private static func dateKey(_ s: String?) -> String {
        guard let s, s.count >= 10 else { return "" }
        return String(s.prefix(10))
    }

    /// Parcel status_code 8 = "carrier has the shipment info but hasn't
    /// physically received the package yet" (pre-shipment). When Parcel reports
    /// this AND has no `date_expected`, any `confirmed_delivery` in the note is
    /// premature and gets cleared.
    static let preShipmentCode = 8

    /// Parcel status_code -> OhDelhi status, for the codes we act on. Returns
    /// nil for delivered (0 — date only, manual flip) and ambiguous codes.
    static func status(for code: Int) -> DeliveryStatus? {
        switch code {
        case 2: return .shipped
        case 4: return .outForDelivery
        default: return nil
        }
    }

    // ---- API client --------------------------------------------------------

    struct ParcelDelivery: Decodable {
        let carrier_code: String
        let description: String?
        let status_code: Int
        let tracking_number: String
        let date_expected: String?
    }

    private struct ParcelResponse: Decodable {
        let success: Bool
        let error_message: String?
        let deliveries: [ParcelDelivery]?
    }

    private func fetchDeliveries(apiKey: String) async throws -> [ParcelDelivery] {
        var components = URLComponents(string: "https://api.parcel.app/external/deliveries/")!
        components.queryItems = [URLQueryItem(name: "filter_mode", value: "active")]
        guard let url = components.url else {
            throw NSError(domain: "ParcelTracker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ParcelTracker", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }

        switch http.statusCode {
        case 200: break
        case 401, 403:
            throw NSError(domain: "ParcelTracker", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Auth rejected — check API key"])
        case 429:
            throw NSError(domain: "ParcelTracker", code: 429,
                          userInfo: [NSLocalizedDescriptionKey: "Rate limited (20/hour) — backing off"])
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ParcelTracker", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(body.prefix(120))"])
        }

        let decoded = try JSONDecoder().decode(ParcelResponse.self, from: data)
        guard decoded.success else {
            throw NSError(domain: "ParcelTracker", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: decoded.error_message ?? "Parcel API reported failure"])
        }
        return decoded.deliveries ?? []
    }

    // ---- Credentials -------------------------------------------------------

    private struct Credentials: Decodable { let api_key: String }

    private func loadAPIKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parcel/credentials.json")
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
            at: url, includingPropertiesForKeys: nil,
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

    /// Parcel dates look like "2026-06-21 16:00:00"; we only need the calendar
    /// day, so take the leading "yyyy-MM-dd".
    static func parseDate(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        return isoFormatter.date(from: String(s.prefix(10)))
    }
}

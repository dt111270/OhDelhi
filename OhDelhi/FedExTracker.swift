//
//  FedExTracker.swift
//  OhDelhi
//
//  Reads FedEx SMS notifications from the vault's `03.95 texts/` folder and
//  writes the parsed due date to matching delivery notes' `confirmed_delivery`
//  frontmatter field.
//
//  Text format (real example, June 2026):
//    Your FedEx package is due for delivery by 23/06. To reschedule, go to
//    https://fedex.com/fedextrack?t=382086027044&l=en_GB&st=…
//
//  Detection:  `from: [[FedEx]]` in frontmatter (Obsidian wiki-link style).
//  Tracking #: URL query parameter `t=` (12–15 digits).
//  Date:       `by DD/MM` — year inferred (current year; next year if the
//              resulting date is more than 60 days in the past, to handle
//              year-boundary edge cases).
//

import Foundation
import Observation

// MARK: - Tracker

@Observable
final class FedExTracker {

    // ---- Public state ------------------------------------------------------

    private(set) var isRunning:    Bool    = false
    private(set) var lastScan:     Date?   = nil
    private(set) var lastStatus:   String  = "Never run"
    private(set) var lastError:    String? = nil
    private(set) var recentUpdates: [TrackingUpdate] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            restartTimer()
        }
    }

    var textsFolder: String {
        didSet { UserDefaults.standard.set(textsFolder, forKey: Self.folderKey) }
    }

    // ---- Init --------------------------------------------------------------

    private static let enabledKey = "OhDelhi.fedexTracker.enabled"
    private static let folderKey  = "OhDelhi.fedexTracker.textsFolder"
    private static let interval: TimeInterval = 15 * 60   // 15 min

    private var timer: Timer?

    init() {
        self.isEnabled   = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.textsFolder = UserDefaults.standard.string(forKey: Self.folderKey)
            ?? Self.defaultTextsFolder
        restartTimer()
    }

    private static var defaultTextsFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DTObs/00-09 DTOS/03 Working Folders/03.95 texts")
            .path(percentEncoded: false)
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

        do {
            let texts      = try loadFedExTexts()
            let deliveries = try loadDeliveries()

            var fresh: [TrackingUpdate] = []
            for text in texts {
                guard let parsed = parseFedExText(text.body) else { continue }
                let matched = matches(parsed.trackingNumber, in: deliveries)
                guard !matched.isEmpty else { continue }

                let iso = Self.isoFormatter.string(from: parsed.dueDate)
                for match in matched {
                    if let existing = match.confirmedDelivery,
                       Calendar.current.isDate(existing, inSameDayAs: parsed.dueDate) {
                        continue
                    }
                    do {
                        try NoteEditor.setField("confirmed_delivery", to: iso, in: match.fileURL)
                        fresh.append(TrackingUpdate(
                            fileURL:                  match.fileURL,
                            item:                     match.item,
                            previousConfirmedDelivery: match.confirmedDelivery,
                            newConfirmedDelivery:     parsed.dueDate,
                            source:                   "FedEx text",
                            timestamp:                Date()
                        ))
                    } catch {
                        lastError = "Couldn't update \(match.fileURL.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }

            recentUpdates = (fresh + recentUpdates).prefix(20).map { $0 }
            lastScan   = Date()
            lastError  = nil
            lastStatus = fresh.isEmpty
                ? "Scanned \(texts.count) texts · no new updates"
                : "Updated \(fresh.count) of \(deliveries.count) deliveries"
        } catch {
            lastError  = error.localizedDescription
            lastStatus = "Scan failed"
        }
    }

    // ---- Texts loading -----------------------------------------------------

    private struct RawText {
        let fileURL: URL
        let body:    String
    }

    private func loadFedExTexts() throws -> [RawText] {
        let folder = URL(fileURLWithPath: textsFolder, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents
            .filter  { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                guard isFedEx(text) else { return nil }
                let body = bodyContent(of: text)
                return RawText(fileURL: url, body: body)
            }
    }

    private func isFedEx(_ noteText: String) -> Bool {
        // Match `from: FedEx` or `from: [[FedEx]]` — the Obsidian SMS exporter
        // stores it as plain text (no brackets). Case-insensitive.
        let head = noteText.prefix(400).lowercased()
        return head.contains("from: fedex") || head.contains("from: [[fedex]]")
    }

    private func bodyContent(of noteText: String) -> String {
        guard noteText.hasPrefix("---\n") else { return noteText }
        let after = noteText.dropFirst(4)
        guard let end = after.range(of: "\n---") else { return String(after) }
        return String(after[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- Body parsing ------------------------------------------------------

    private struct ParsedFedExText {
        let trackingNumber: String
        let dueDate:        Date
    }

    private func parseFedExText(_ body: String) -> ParsedFedExText? {
        guard let tracking = extractTrackingNumber(from: body) else { return nil }
        guard let date     = extractDueDate(from: body)        else { return nil }
        return ParsedFedExText(trackingNumber: tracking, dueDate: date)
    }

    // FedEx tracking number lives in the URL: `?t=382086027044&`
    private static let trackingPattern = try! NSRegularExpression(
        pattern: "[?&]t=(\\d{10,15})",
        options: []
    )

    private func extractTrackingNumber(from text: String) -> String? {
        let nsText = text as NSString
        guard let m = Self.trackingPattern.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ), m.numberOfRanges >= 2 else { return nil }
        return nsText.substring(with: m.range(at: 1))
    }

    // Date format: `by 23/06` (DD/MM, no year)
    private static let datePattern = try! NSRegularExpression(
        pattern: "by\\s+(\\d{1,2})/(\\d{1,2})",
        options: [.caseInsensitive]
    )

    private func extractDueDate(from text: String) -> Date? {
        let nsText = text as NSString
        let range  = NSRange(location: 0, length: nsText.length)
        guard let m = Self.datePattern.firstMatch(in: text, range: range),
              m.numberOfRanges >= 3 else { return nil }

        guard let day   = Int(nsText.substring(with: m.range(at: 1))),
              let month = Int(nsText.substring(with: m.range(at: 2))) else { return nil }

        let cal  = Calendar.current
        let now  = Date()
        var comps = DateComponents()
        comps.day   = day
        comps.month = month
        comps.year  = cal.component(.year, from: now)

        // If the resulting date is more than 60 days in the past, bump the
        // year — handles texts received near a year boundary.
        if let candidate = cal.date(from: comps) {
            if candidate < now.addingTimeInterval(-60 * 86_400) {
                comps.year! += 1
            }
            return cal.date(from: comps)
        }
        return nil
    }

    // ---- Deliveries loading + matching -------------------------------------

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
            .filter     { $0.pathExtension.lowercased() == "md" }
            .compactMap { DeliveryParser.parse(fileURL: $0) }
    }

    private static var defaultDeliveriesFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DTObs/00-09 DTOS/03 Working Folders/03.10 Deliveries")
            .path(percentEncoded: false)
    }

    /// Returns ALL deliveries whose tracking number matches — multi-item orders
    /// share a single FedEx tracking number across several notes.
    private func matches(_ trackingNumber: String, in deliveries: [Delivery]) -> [Delivery] {
        deliveries.filter { d in
            guard d.status != .delivered else { return false }
            if let url = d.trackingURLString, url.contains(trackingNumber) { return true }
            if let tn  = d.trackingNumber,   tn.contains(trackingNumber)   { return true }
            return false
        }
    }

    // ---- Formatters --------------------------------------------------------

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

//
//  RoyalMailTracker.swift
//  OhDelhi
//
//  First tracking provider: reads Royal Mail SMS notifications from the
//  vault's `03.95 texts/` folder and writes the parsed due date to the
//  matching delivery note's `confirmed_delivery` frontmatter field.
//
//  How matching works:
//
//   • Royal Mail texts include the RM tracking number inside a `ryml.me`
//     short-URL (e.g. `https://ryml.me/?GV363140696GB&…`).
//   • Delivery notes created by the `4-delivery-report` skill always include
//     the RM tracking number somewhere inside `tracking_url` — even when the
//     note's `tracking_number` field is something else (e.g. the international
//     Yun Express ID for parcels that travel via two networks). So we extract
//     a Royal Mail-format tracking number (`[A-Z]{2}\d{9}[A-Z]{2}`) from both
//     ends and match on it.
//
//  Future providers (DHL API, FedEx API, Amazon Mail.app scrape) can follow
//  the same shape and live alongside this one. If a third provider lands,
//  extract a protocol and a coordinator.
//

import Foundation
import Observation

// MARK: - Update record

struct TrackingUpdate: Identifiable, Hashable {
    let id = UUID()
    let fileURL: URL
    let item: String
    let previousConfirmedDelivery: Date?
    let newConfirmedDelivery: Date
    let source: String     // "Royal Mail text"
    let timestamp: Date
}

// MARK: - Tracker

@Observable
final class RoyalMailTracker {

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

    var textsFolder: String {
        didSet { UserDefaults.standard.set(textsFolder, forKey: Self.folderKey) }
    }

    /// Whether to also scan Mail.app for Royal Mail delivery emails. Shares the
    /// `OhDelhi.mailScanner.watchedMailboxes` setting with AmazonMailTracker.
    var emailScanEnabled: Bool {
        didSet { UserDefaults.standard.set(emailScanEnabled, forKey: Self.emailEnabledKey) }
    }

    /// Comma-separated list of Mail.app mailbox names to scan for RM emails.
    /// Shares the same UserDefaults key as AmazonMailTracker so the user only
    /// configures it once.
    var watchedMailboxes: String {
        didSet { UserDefaults.standard.set(watchedMailboxes, forKey: Self.mailboxesKey) }
    }

    // ---- Init --------------------------------------------------------------

    private static let enabledKey    = "OhDelhi.rmTracker.enabled"
    private static let emailEnabledKey = "OhDelhi.rmTracker.emailScanEnabled"
    private static let folderKey     = "OhDelhi.rmTracker.textsFolder"
    private static let mailboxesKey  = "OhDelhi.mailScanner.watchedMailboxes"
    private static let interval: TimeInterval = 15 * 60   // 15 min

    private var timer: Timer?

    init() {
        self.isEnabled        = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.emailScanEnabled = UserDefaults.standard.bool(forKey: Self.emailEnabledKey)
        self.textsFolder      = UserDefaults.standard.string(forKey: Self.folderKey)
            ?? Self.defaultTextsFolder
        self.watchedMailboxes = UserDefaults.standard.string(forKey: Self.mailboxesKey)
            ?? "Inbox, @4 Delivery"
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

    /// Scan texts and (optionally) Mail.app emails for Royal Mail delivery
    /// updates. Safe to call repeatedly — `NoteEditor.setField` now skips the
    /// write when content is unchanged, and `recentUpdates` only records actual
    /// changes so a no-op scan leaves the list as it was.
    @MainActor
    func refreshNow() async {
        if isRunning { return }
        isRunning = true
        defer { isRunning = false }

        do {
            // Source 1: SMS notes in the vault texts folder.
            let texts = try loadRoyalMailTexts()

            // Source 2: Royal Mail emails in Mail.app (if enabled). Failures
            // here are non-fatal — fall back to texts-only.
            var emailBodies: [String] = []
            if emailScanEnabled {
                emailBodies = (try? await fetchRoyalMailEmailBodies()) ?? []
            }

            let deliveries = try loadDeliveries()

            // Unified source list: (body, humanReadableSource)
            let sources: [(body: String, source: String)] =
                texts.map { ($0.body, "Royal Mail text") }
                + emailBodies.map { ($0, "Royal Mail email") }

            var fresh: [TrackingUpdate] = []
            for (body, sourceName) in sources {
                guard let parsed = parseRoyalMailText(body) else { continue }
                let matched = matches(parsed.trackingNumber, in: deliveries)
                guard !matched.isEmpty else { continue }

                let iso = Self.isoFormatter.string(from: parsed.dueDate)
                for match in matched {
                    // Skip the write if the existing value already matches.
                    if let existing = match.confirmedDelivery,
                       Calendar.current.isDate(existing, inSameDayAs: parsed.dueDate) {
                        continue
                    }

                    do {
                        try NoteEditor.setField(
                            "confirmed_delivery",
                            to: iso,
                            in: match.fileURL
                        )
                        fresh.append(TrackingUpdate(
                            fileURL: match.fileURL,
                            item: match.item,
                            previousConfirmedDelivery: match.confirmedDelivery,
                            newConfirmedDelivery: parsed.dueDate,
                            source: sourceName,
                            timestamp: Date()
                        ))
                    } catch {
                        // Don't fail the whole batch — log and carry on.
                        lastError = "Couldn't update \(match.fileURL.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }

            // Prepend new updates so the most recent are on top; cap at 20.
            recentUpdates = (fresh + recentUpdates).prefix(20).map { $0 }
            lastScan = Date()
            lastError = nil
            let sourceDesc = emailScanEnabled ? "\(texts.count) texts + \(emailBodies.count) emails" : "\(texts.count) texts"
            lastStatus = fresh.isEmpty
                ? "Scanned \(sourceDesc) · no new updates"
                : "Updated \(fresh.count) of \(deliveries.count) deliveries"
        } catch {
            lastError = error.localizedDescription
            lastStatus = "Scan failed"
        }
    }

    // ---- Texts loading -----------------------------------------------------

    private struct RawText {
        let fileURL: URL
        let body: String
    }

    /// Pull every `.md` file in the texts folder whose frontmatter declares
    /// `from: RoyalMail` (case-insensitive). Returns body content only — the
    /// frontmatter itself isn't useful for parsing the date / tracking number.
    private func loadRoyalMailTexts() throws -> [RawText] {
        let folder = URL(fileURLWithPath: textsFolder, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                guard isRoyalMail(text) else { return nil }
                let body = bodyContent(of: text)
                return RawText(fileURL: url, body: body)
            }
    }

    private func isRoyalMail(_ noteText: String) -> Bool {
        // Look for `from: RoyalMail` (or `royal mail` with a space) inside the
        // opening frontmatter block. Cheap substring check on the first few
        // hundred bytes is enough.
        let head = noteText.prefix(400)
        let lc = head.lowercased()
        return lc.contains("from: royalmail") || lc.contains("from: royal mail")
    }

    private func bodyContent(of noteText: String) -> String {
        guard noteText.hasPrefix("---\n") else { return noteText }
        let after = noteText.dropFirst(4)
        guard let end = after.range(of: "\n---") else { return String(after) }
        return String(after[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- Body parsing ------------------------------------------------------

    private struct ParsedRMText {
        let trackingNumber: String
        let dueDate: Date
    }

    /// Royal Mail body shape:
    ///   `Your <Vendor> parcel is due <Day> <D> <Mon> <YYYY>. View delivery
    ///    options at https://ryml.me/?<TRACKING>&…`
    private func parseRoyalMailText(_ body: String) -> ParsedRMText? {
        guard let tracking = extractTrackingNumber(from: body) else { return nil }
        guard let date     = extractDueDate(from: body) else { return nil }
        return ParsedRMText(trackingNumber: tracking, dueDate: date)
    }

    private static let trackingPattern = try! NSRegularExpression(
        pattern: "[A-Z]{2}\\d{9}[A-Z]{2}",
        options: []
    )

    private func extractTrackingNumber(from text: String) -> String? {
        let nsText = text as NSString
        guard let m = Self.trackingPattern.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return nsText.substring(with: m.range)
    }

    // SMS format: `due Sat 23 May 2026`
    private static let datePattern = try! NSRegularExpression(
        pattern: "due\\s+([A-Za-z]{3,9}\\s+\\d{1,2}(?:st|nd|rd|th)?\\s+[A-Za-z]{3,9}\\s+\\d{4})",
        options: [.caseInsensitive]
    )

    // Email format: `Delivery is due:\n\n*Friday, 19 June 2026*`
    private static let emailDatePattern = try! NSRegularExpression(
        pattern: "Delivery is due:\\s*\\n+\\s*\\*?([A-Za-z]+,?\\s+\\d{1,2}\\s+[A-Za-z]+\\s+\\d{4})",
        options: [.caseInsensitive]
    )

    private static let dateInputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static let dateInputFormatterLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMM yyyy"
        return f
    }()

    // Email uses full month name and a comma after the day name.
    private static let emailDateFormatterFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()

    // Fallback without the comma (defensive, in case RM drops it).
    private static let emailDateFormatterFullNoComma: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    private func extractDueDate(from text: String) -> Date? {
        let nsText = text as NSString
        let range  = NSRange(location: 0, length: nsText.length)

        // Try SMS format first: "due Sat 23 May 2026"
        if let m = Self.datePattern.firstMatch(in: text, range: range), m.numberOfRanges >= 2 {
            var raw = nsText.substring(with: m.range(at: 1))
            raw = raw.replacingOccurrences(of: "(\\d+)(st|nd|rd|th)", with: "$1", options: .regularExpression)
            if let d = Self.dateInputFormatter.date(from: raw)     { return d }
            if let d = Self.dateInputFormatterLong.date(from: raw) { return d }
        }

        // Try email format: "Delivery is due:\n\n*Friday, 19 June 2026*"
        if let m = Self.emailDatePattern.firstMatch(in: text, range: range), m.numberOfRanges >= 2 {
            var raw = nsText.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Self.emailDateFormatterFull.date(from: raw)        { return d }
            if let d = Self.emailDateFormatterFullNoComma.date(from: raw) { return d }
        }

        return nil
    }

    // ---- Email scanning ---------------------------------------------------

    /// The `watchedMailboxes` setting as a trimmed array (splits on commas).
    private var watchedMailboxesList: [String] {
        watchedMailboxes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Run the Royal Mail email AppleScript and return the plain-text body of
    /// every matching message. Failures propagate so `refreshNow` can decide
    /// whether to log them.
    private func fetchRoyalMailEmailBodies() async throws -> [String] {
        let mailboxes = watchedMailboxesList
        guard !mailboxes.isEmpty else { return [] }
        let script = buildRMEmailScript(mailboxes: mailboxes)
        let output = try await runAppleScript(script)
        return parseEmailBodies(output)
    }

    /// Inject the mailbox list into the AppleScript template.
    private func buildRMEmailScript(mailboxes: [String]) -> String {
        let escaped = mailboxes.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let asList = escaped.map { "\"\($0)\"" }.joined(separator: ", ")
        return Self.rmEmailScript
            .replacingOccurrences(of: "{{MAILBOXES_LIST}}", with: "{\(asList)}")
    }

    /// Parse the `===RM-MSG===` / `===RM-END===` delimited output into an array
    /// of body strings.
    private func parseEmailBodies(_ output: String) -> [String] {
        let chunks = output.components(separatedBy: "===RM-MSG===")
        return chunks.compactMap { chunk -> String? in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let end = trimmed.range(of: "===RM-END===") else { return nil }
            return String(trimmed[..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func runAppleScript(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let outputPipe = Pipe()
            let errorPipe  = Pipe()
            process.standardOutput = outputPipe
            process.standardError  = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData  = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outString  = String(data: outputData, encoding: .utf8) ?? ""
            let errString  = String(data: errorData,  encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw NSError(
                    domain: "RoyalMailTracker",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errString.isEmpty ? "osascript failed" : errString]
                )
            }
            return outString
        }.value
    }

    /// AppleScript that scans the watched mailboxes for Royal Mail emails from
    /// the last 30 days and emits each message body between delimiters.
    private static let rmEmailScript: String = """
on run
    set userTargetMailboxes to {{MAILBOXES_LIST}}
    set output to ""
    tell application "Mail"
        set cutoffDate to ((current date) - (30 * days))
        set targetMailboxes to {}
        repeat with anAcct in accounts
            try
                repeat with aMbox in mailboxes of anAcct
                    if userTargetMailboxes contains (name of aMbox) then
                        set end of targetMailboxes to aMbox
                    end if
                end repeat
            on error
            end try
        end repeat
        repeat with aMbox in targetMailboxes
            try
                set msgList to (messages of aMbox whose (date received > cutoffDate) and (sender contains "royalmail"))
                repeat with aMsg in msgList
                    try
                        set output to output & "===RM-MSG===" & linefeed
                        set output to output & (content of aMsg) & linefeed
                        set output to output & "===RM-END===" & linefeed
                    on error
                    end try
                end repeat
            on error
            end try
        end repeat
    end tell
    return output
end run
"""

    // ---- Deliveries loading + matching ------------------------------------

    /// Read the current set of delivery notes directly from disk. Independent
    /// of `DeliveryStore` so the tracker can run from the Timer without
    /// having to thread the store reference through every callsite.
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

    /// Find all deliveries whose `tracking_url` (or `tracking_number`) contains
    /// the Royal Mail tracking number. Returns an array because multi-item orders
    /// share a single tracking number across several notes.
    /// Skips delivered ones — pointless to rewrite confirmed_delivery on arrivals.
    private func matches(_ trackingNumber: String, in deliveries: [Delivery]) -> [Delivery] {
        return deliveries.filter { d in
            guard d.status != .delivered else { return false }
            if let url = d.trackingURLString, url.contains(trackingNumber) { return true }
            if let tn  = d.trackingNumber,  tn.contains(trackingNumber)    { return true }
            return false
        }
    }

    // ---- Formatters --------------------------------------------------------

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

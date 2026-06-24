//
//  AmazonMailTracker.swift
//  OhDelhi
//
//  Phase 2: pull Amazon delivery data into OhDelhi by scraping Mail.app.
//
//  Mail.app already has the user's Outlook account configured and indexed, so
//  we shell out to `osascript` to ask Mail for messages from `*@amazon.*`
//  (in the @4 Delivery folder + Inbox, last 30 days), parse the structured
//  text it returns, and dispatch to one of four parsers based on subject.
//
//  Subject category → action:
//    Order Confirmation  → create new note (if none with this order_number)
//    Arriving / Shipped  → update expected_delivery on the matching note
//    Out for Delivery    → write confirmed_delivery, flip status to out-for-delivery
//    Delivered           → write confirmed_delivery, leave status alone (the
//                          user marks delivered manually, so a false-positive
//                          delivered email doesn't lose the chase-for-refund
//                          handle)
//
//  Status only ever moves forward (uses `pipelineRank` to guard against an
//  out-of-order email downgrading a parcel from out-for-delivery to shipped).
//

import Foundation
import Observation

// MARK: - Public actions (surfaced in Settings)

enum MailActionKind: String {
    case createdNote      = "Created"
    case updatedExpected  = "Updated expected"
    case updatedConfirmed = "Updated confirmed"
    case statusFlipped    = "Status flipped"
    case skipped          = "Skipped"
    case unrecognised     = "Unrecognised subject"
}

struct MailDeliveryAction: Identifiable, Hashable {
    let id = UUID()
    let kind: MailActionKind
    let item: String
    let detail: String
    let timestamp: Date
}

// MARK: - Tracker

@Observable
final class AmazonMailTracker {

    // ---- Public state ------------------------------------------------------

    private(set) var isRunning: Bool = false
    private(set) var lastScan: Date? = nil
    private(set) var lastStatus: String = "Never run"
    private(set) var lastError: String? = nil
    private(set) var recentActions: [MailDeliveryAction] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            restartTimer()
        }
    }

    /// Comma-separated list of Mail.app mailbox names to scan. Shared across
    /// mail-based trackers (FedEx will read the same key) so changes propagate.
    /// Case-insensitive matching against AppleScript's `name of mailbox`.
    var watchedMailboxes: String {
        didSet { UserDefaults.standard.set(watchedMailboxes, forKey: Self.mailboxesKey) }
    }

    // ---- Init --------------------------------------------------------------

    private static let enabledKey     = "OhDelhi.amzTracker.enabled"
    private static let mailboxesKey   = "OhDelhi.mailScanner.watchedMailboxes"
    private static let lastScanKey    = "OhDelhi.amzTracker.lastScanDate"
    private static let interval: TimeInterval = 15 * 60   // 15 min

    /// Date of the last successful mail fetch. Used as the `since:` cutoff on
    /// the next run so Mail.app only returns genuinely new messages.
    /// Defaults to 30 days ago on first run (full back-fill window).
    private var lastMailFetchDate: Date {
        get {
            (UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date)
                ?? Date().addingTimeInterval(-30 * 24 * 3600)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastScanKey) }
    }

    private var timer: Timer?

    init() {
        self.isEnabled       = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.watchedMailboxes = UserDefaults.standard.string(forKey: Self.mailboxesKey)
            ?? "Inbox, @4 Delivery"
        restartTimer()
    }

    /// Parse the comma-separated `watchedMailboxes` field into a clean
    /// list. Trims whitespace; drops empties; preserves user-supplied case
    /// (AppleScript's comparison ignores it anyway).
    private var watchedMailboxesList: [String] {
        watchedMailboxes
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
            let since = lastMailFetchDate
            let messages = try await MailFetcher.fetchAmazonMessages(in: watchedMailboxesList, since: since)

            // Record a successful fetch immediately — even when nothing came
            // back, we've confirmed the folder is quiet up to this moment.
            // (Errors leave lastMailFetchDate unchanged so the window stays
            // wide and we don't miss anything on the next attempt.)
            lastMailFetchDate = Date()

            guard !messages.isEmpty else {
                lastScan = Date()
                lastStatus = "No new mail since \(Self.short(since))"
                return
            }

            let deliveries = try loadDeliveries()
            let deliveriesFolder = URL(fileURLWithPath: Self.deliveriesFolder, isDirectory: true)

            // Process in chronological order so later emails (which carry more
            // authoritative info) overwrite earlier ones cleanly.
            let chronological = messages.sorted { $0.receivedAt < $1.receivedAt }

            var fresh: [MailDeliveryAction] = []
            var unrecognisedCount = 0
            var workingSet = deliveries

            for msg in chronological {
                let category = AmazonEmailParser.categorize(subject: msg.subject)
                if category == .unknown {
                    unrecognisedCount += 1
                    // Surface the subject in the recent-actions list so David
                    // can tell us which patterns the categoriser missed.
                    fresh.append(MailDeliveryAction(
                        kind: .unrecognised,
                        item: msg.subject,
                        detail: "from \(msg.sender)",
                        timestamp: msg.receivedAt
                    ))
                    continue
                }
                let actions = applyMessage(
                    msg,
                    category: category,
                    deliveries: workingSet,
                    deliveriesFolder: deliveriesFolder
                )
                fresh.append(contentsOf: actions.filter { $0.kind != .skipped })
                workingSet = (try? loadDeliveries()) ?? workingSet
            }

            recentActions = (fresh + recentActions).prefix(30).map { $0 }
            lastScan = Date()
            lastError = nil
            let changes = fresh.filter { $0.kind != .unrecognised }.count
            var bits: [String] = []
            bits.append("Scanned \(messages.count) email\(messages.count == 1 ? "" : "s")")
            if changes > 0 {
                bits.append("\(changes) change\(changes == 1 ? "" : "s") applied")
            } else {
                bits.append("no changes")
            }
            if unrecognisedCount > 0 {
                bits.append("\(unrecognisedCount) unrecognised")
            }
            lastStatus = bits.joined(separator: " · ")
        } catch {
            lastError = error.localizedDescription
            lastStatus = "Scan failed"
        }
    }

    // ---- Application --------------------------------------------------------

    /// Apply one mail message. Returns whatever actions resulted (could be
    /// multiple — e.g. an out-for-delivery email writes confirmed_delivery AND
    /// flips status).
    private func applyMessage(
        _ msg: MailMessage,
        category: AmazonEmailParser.Category,
        deliveries: [Delivery],
        deliveriesFolder: URL
    ) -> [MailDeliveryAction] {

        // Multi-item subjects (`… and N more item(s)`) take a different path
        // through both creation and status-update — items are addressed
        // individually by ASIN rather than the order as a whole.
        let isMulti = AmazonEmailParser.isMultiItemSubject(msg.subject)

        switch category {

        case .orderConfirmation:
            if isMulti {
                return applyMultiOrderConfirmation(msg, deliveries: deliveries, deliveriesFolder: deliveriesFolder)
            }
            guard let parsed = AmazonEmailParser.parseOrderConfirmation(msg) else { return [] }
            // Dedupe against existing notes by order_number — if the skill or
            // a previous OhDelhi scan already made the note, do nothing.
            if deliveries.contains(where: { $0.orderNumber == parsed.orderNumber }) {
                return []
            }
            do {
                let url = try AmazonNoteBuilder.write(
                    confirmation: parsed,
                    message: msg,
                    in: deliveriesFolder
                )
                return [MailDeliveryAction(
                    kind: .createdNote,
                    item: parsed.item,
                    detail: "Order #\(parsed.orderNumber) · \(url.lastPathComponent)",
                    timestamp: Date()
                )]
            } catch {
                lastError = "Couldn't create note for \(parsed.orderNumber): \(error.localizedDescription)"
                return []
            }

        case .arriving:
            if isMulti {
                return applyMultiStatusUpdate(msg, category: category, deliveries: deliveries)
            }
            guard let parsed = AmazonEmailParser.parseDeliveryUpdate(msg) else { return [] }
            guard let match = deliveries.first(where: { $0.orderNumber == parsed.orderNumber }) else { return [] }
            var out: [MailDeliveryAction] = []
            out.append(contentsOf: updateExpected(on: match, to: parsed.deliveryDate))
            // Forward-flip status to .shipped. The forwardStatus helper's
            // pipelineRank check means this is a no-op if the parcel is
            // already at out-for-delivery or delivered.
            if let action = forwardStatus(on: match, to: .shipped) { out.append(action) }
            stampShipmentIdIfNeeded(on: match, from: msg.body)
            stampAsinIfNeeded(on: match, from: msg.body)
            return out

        case .outForDelivery:
            if isMulti {
                return applyMultiStatusUpdate(msg, category: category, deliveries: deliveries)
            }
            let text = msg.subject + "\n" + msg.body
            guard let orderNumber = AmazonEmailParser.extractOrderNumber(from: text) else { return [] }
            guard let match = deliveries.first(where: { $0.orderNumber == orderNumber }) else { return [] }
            var out: [MailDeliveryAction] = []
            // For OFD, the email's received date IS the delivery date by
            // definition. Body-extracted dates pick up the wrong field too
            // often (original order date, original ETA, tracking-history
            // entries…). Same applies to the Delivered case below.
            if let action = updateConfirmed(on: match, to: msg.receivedAt) { out.append(action) }
            if let action = forwardStatus(on: match, to: .outForDelivery) { out.append(action) }
            stampShipmentIdIfNeeded(on: match, from: msg.body)
            stampAsinIfNeeded(on: match, from: msg.body)
            return out

        case .delivered:
            if isMulti {
                return applyMultiStatusUpdate(msg, category: category, deliveries: deliveries)
            }
            let text = msg.subject + "\n" + msg.body
            guard let orderNumber = AmazonEmailParser.extractOrderNumber(from: text) else { return [] }
            guard let match = deliveries.first(where: { $0.orderNumber == orderNumber }) else { return [] }
            // IMPORTANT: stamp confirmed_delivery (received date is the
            // delivery date) but do NOT flip status. The user retains the
            // manual mark-as-delivered step on purpose; a false-positive
            // delivered email mustn't lose the refund handle.
            var out: [MailDeliveryAction] = []
            if let action = updateConfirmed(on: match, to: msg.receivedAt) {
                out.append(action)
            }
            stampShipmentIdIfNeeded(on: match, from: msg.body)
            stampAsinIfNeeded(on: match, from: msg.body)
            return out

        case .unknown:
            return []
        }
    }

    /// Multi-item order confirmation: create one note per ASIN in the body,
    /// all sharing the same order_number. Dedupes per (order_number, asin)
    /// so a re-scan or a partial-create-then-rerun is idempotent.
    private func applyMultiOrderConfirmation(
        _ msg: MailMessage,
        deliveries: [Delivery],
        deliveriesFolder: URL
    ) -> [MailDeliveryAction] {
        let orders = AmazonEmailParser.parseMultiOrderConfirmations(msg)
        guard !orders.isEmpty else { return [] }

        var actions: [MailDeliveryAction] = []
        // Each order has a distinct order_number, so per-order dedup against the
        // same `deliveries` snapshot is sufficient (no cross-order collisions).
        for order in orders {
            do {
                let created = try AmazonNoteBuilder.writeMultiItem(
                    order: order,
                    message: msg,
                    existing: deliveries,
                    in: deliveriesFolder
                )
                actions.append(contentsOf: created.map { (url, item) in
                    MailDeliveryAction(
                        kind: .createdNote,
                        item: item.name,
                        detail: "Order #\(order.orderNumber) · \(url.lastPathComponent)",
                        timestamp: Date()
                    )
                })
            } catch {
                lastError = "Couldn't create multi-item notes for \(order.orderNumber): \(error.localizedDescription)"
            }
        }
        return actions
    }

    /// Multi-item status update (Dispatched / OFD / Delivered): find the
    /// notes for the items the email actually covers (matched by
    /// (order_number, asin)) and apply the appropriate action to each.
    /// Falls back to all notes for the order if no ASINs surface — keeps
    /// us no worse than the pre-multi-item behaviour on weird email layouts.
    private func applyMultiStatusUpdate(
        _ msg: MailMessage,
        category: AmazonEmailParser.Category,
        deliveries: [Delivery]
    ) -> [MailDeliveryAction] {
        guard let update = AmazonEmailParser.parseMultiStatusUpdate(msg, category: category) else { return [] }
        let candidates = deliveries.filter { $0.orderNumber == update.orderNumber }
        guard !candidates.isEmpty else { return [] }

        // Match by ASIN if the body gave us any. Otherwise fall back to
        // every note for the order.
        let targets: [Delivery]
        if update.asins.isEmpty {
            targets = candidates
        } else {
            let setAsins = Set(update.asins)
            targets = candidates.filter { d in
                guard let a = d.asin else { return false }
                return setAsins.contains(a)
            }
        }
        guard !targets.isEmpty else { return [] }

        var out: [MailDeliveryAction] = []
        for d in targets {
            switch category {
            case .arriving:
                out.append(contentsOf: updateExpected(on: d, to: update.date))
                if let a = forwardStatus(on: d, to: .shipped) { out.append(a) }
            case .outForDelivery:
                if let a = updateConfirmed(on: d, to: update.date) { out.append(a) }
                if let a = forwardStatus(on: d, to: .outForDelivery) { out.append(a) }
            case .delivered:
                // Stamp confirmed_delivery but leave status alone (same
                // refund-handle reasoning as the single-item path).
                if let a = updateConfirmed(on: d, to: update.date) { out.append(a) }
            case .orderConfirmation, .unknown:
                break
            }
            if let sid = update.shipmentId { stampShipmentIdIfMissing(on: d, value: sid) }
        }
        return out
    }

    /// Idempotently stamp `shipment_id` on a note when the status-update
    /// email contains one and the note doesn't have it yet.
    private func stampShipmentIdIfNeeded(on d: Delivery, from body: String) {
        guard let sid = AmazonEmailParser.extractShipmentId(from: body) else { return }
        stampShipmentIdIfMissing(on: d, value: sid)
    }

    private func stampShipmentIdIfMissing(on d: Delivery, value sid: String) {
        guard (d.shipmentId ?? "").isEmpty else { return }
        do {
            try NoteEditor.setField("shipment_id", to: sid, in: d.fileURL)
        } catch {
            // Non-fatal — log but don't break the status update flow.
            lastError = "Couldn't write shipment_id on \(d.fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Same idea for `asin` — useful for legacy notes that pre-date the
    /// ASIN-aware parser. The note's matched on order_number, so we trust
    /// the first ASIN in the body if the note has none.
    private func stampAsinIfNeeded(on d: Delivery, from body: String) {
        guard (d.asin ?? "").isEmpty else { return }
        guard let first = AmazonEmailParser.extractAsinAnchors(from: body).first?.asin else { return }
        do {
            try NoteEditor.setField("asin", to: first, in: d.fileURL)
        } catch {
            lastError = "Couldn't write asin on \(d.fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func updateExpected(on d: Delivery, to date: Date) -> [MailDeliveryAction] {
        // Skip if already correct.
        if let existing = d.expectedDelivery,
           Calendar.current.isDate(existing, inSameDayAs: date) {
            return []
        }
        do {
            try NoteEditor.setField(
                "expected_delivery",
                to: Self.iso(date),
                in: d.fileURL
            )
            return [MailDeliveryAction(
                kind: .updatedExpected,
                item: d.item,
                detail: "expected → \(Self.short(date))",
                timestamp: Date()
            )]
        } catch {
            lastError = "Couldn't update \(d.fileURL.lastPathComponent): \(error.localizedDescription)"
            return []
        }
    }

    private func updateConfirmed(on d: Delivery, to date: Date) -> MailDeliveryAction? {
        if let existing = d.confirmedDelivery,
           Calendar.current.isDate(existing, inSameDayAs: date) {
            return nil
        }
        do {
            try NoteEditor.setField(
                "confirmed_delivery",
                to: Self.iso(date),
                in: d.fileURL
            )
            return MailDeliveryAction(
                kind: .updatedConfirmed,
                item: d.item,
                detail: "confirmed → \(Self.short(date))",
                timestamp: Date()
            )
        } catch {
            lastError = "Couldn't update \(d.fileURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Set status only if `new` sits strictly later in the pipeline. Stops a
    /// stale "shipped" email from downgrading an already out-for-delivery
    /// parcel.
    private func forwardStatus(on d: Delivery, to new: DeliveryStatus) -> MailDeliveryAction? {
        guard new.pipelineRank > d.status.pipelineRank else { return nil }
        do {
            try NoteEditor.setField("status", to: new.rawValue, in: d.fileURL)
            return MailDeliveryAction(
                kind: .statusFlipped,
                item: d.item,
                detail: "\(d.status.displayName) → \(new.displayName)",
                timestamp: Date()
            )
        } catch {
            lastError = "Couldn't flip status on \(d.fileURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    // ---- Deliveries loading ------------------------------------------------

    private func loadDeliveries() throws -> [Delivery] {
        let url = URL(fileURLWithPath: Self.deliveriesFolder, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { DeliveryParser.parse(fileURL: $0) }
    }

    private static var deliveriesFolder: String {
        UserDefaults.standard.string(forKey: "OhDelhi.deliveriesFolder") ?? defaultDeliveriesFolder
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

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    private static func iso(_ d: Date) -> String   { isoFormatter.string(from: d) }
    private static func short(_ d: Date) -> String { shortFormatter.string(from: d) }
}

// MARK: - Mail.app fetcher

struct MailMessage: Hashable {
    let subject: String
    let sender: String
    let receivedAt: Date
    let messageID: String
    let body: String
}

private enum MailFetcher {

    /// Run the AppleScript via `osascript`, parse the structured text it
    /// returns into `MailMessage`s. `mailboxes` is the user-configurable
    /// list of mailbox names — usually `["Inbox", "@4 Delivery"]`.
    /// `since` is used as the cutoff so Mail.app only returns messages that
    /// arrived after the last successful scan.
    static func fetchAmazonMessages(in mailboxes: [String], since: Date) async throws -> [MailMessage] {
        let script = buildScript(mailboxes: mailboxes, since: since)
        let output = try await runAppleScript(script)
        return parseOutput(output)
    }

    /// Inject the mailbox list and `since` cutoff into the AppleScript
    /// template. The cutoff is expressed as seconds-ago so the script can
    /// compute it with `(current date) - N` — locale-independent and no
    /// string-date parsing needed in AppleScript. A 60-second buffer is added
    /// so emails that land right at the boundary aren't silently skipped.
    private static func buildScript(mailboxes: [String], since: Date) -> String {
        let escaped = mailboxes.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let asList = escaped.map { "\"\($0)\"" }.joined(separator: ", ")
        // How many seconds ago was `since`? Add 60s buffer against boundary races.
        let secondsAgo = max(120, Int(-since.timeIntervalSinceNow) + 60)
        return amazonScript
            .replacingOccurrences(of: "{{MAILBOXES_LIST}}", with: "{\(asList)}")
            .replacingOccurrences(of: "{{SINCE_SECONDS}}", with: String(secondsAgo))
    }

    /// The AppleScript template that walks every Mail account, picks the
    /// mailboxes named in `userTargetMailboxes` (injected at call time), and
    /// emits messages from Amazon senders in the last 30 days as a
    /// structured-text blob.
    private static let amazonScript: String = """
on padded(n)
    if n < 10 then return "0" & (n as string)
    return (n as string)
end padded

on isoDateString(d)
    set y to (year of d) as integer
    set m to (month of d) as integer
    set dd to (day of d) as integer
    set h to (hours of d) as integer
    set mi to (minutes of d) as integer
    set s to (seconds of d) as integer
    return (y as string) & "-" & my padded(m) & "-" & my padded(dd) & " " & my padded(h) & ":" & my padded(mi) & ":" & my padded(s)
end isoDateString

on run
    set userTargetMailboxes to {{MAILBOXES_LIST}}
    set output to ""
    tell application "Mail"
        set cutoffDate to ((current date) - {{SINCE_SECONDS}})
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
                set msgList to (messages of aMbox whose (date received > cutoffDate) and (sender contains "amazon"))
                repeat with aMsg in msgList
                    try
                        set output to output & "===MSG===" & linefeed
                        set output to output & "SUBJECT::" & (subject of aMsg) & linefeed
                        set output to output & "SENDER::" & (sender of aMsg) & linefeed
                        set output to output & "DATE::" & my isoDateString(date received of aMsg) & linefeed
                        set output to output & "ID::" & (message id of aMsg) & linefeed
                        set output to output & "===BODY===" & linefeed
                        set output to output & (content of aMsg) & linefeed
                        set output to output & "===END===" & linefeed
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

    private static func runAppleScript(_ source: String) async throws -> String {
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
                    domain: "AmazonMailTracker",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errString.isEmpty ? "osascript failed" : errString]
                )
            }
            return outString
        }.value
    }

    private static let parseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func parseOutput(_ output: String) -> [MailMessage] {
        var messages: [MailMessage] = []
        let chunks = output.components(separatedBy: "===MSG===")
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let bodyStart = trimmed.range(of: "===BODY==="),
                  let bodyEnd   = trimmed.range(of: "===END===") else { continue }

            let headerPart = String(trimmed[..<bodyStart.lowerBound])
            let bodyPart   = String(trimmed[bodyStart.upperBound..<bodyEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var headers: [String: String] = [:]
            for line in headerPart.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let sep = line.range(of: "::") else { continue }
                let key   = String(line[..<sep.lowerBound])
                let value = String(line[sep.upperBound...])
                headers[key] = value
            }

            guard let subject = headers["SUBJECT"],
                  let sender  = headers["SENDER"],
                  let dateStr = headers["DATE"],
                  let date    = parseDateFormatter.date(from: dateStr),
                  let id      = headers["ID"] else { continue }

            messages.append(MailMessage(
                subject: subject,
                sender: sender,
                receivedAt: date,
                messageID: id,
                body: bodyPart
            ))
        }
        return messages
    }
}

// MARK: - Email parser

private enum AmazonEmailParser {

    enum Category {
        case orderConfirmation
        case arriving
        case outForDelivery
        case delivered
        case unknown
    }

    /// Subject-line dispatch. Order matters: `delivered` and `out for delivery`
    /// have to be checked before generic "arriving" / "order" tokens.
    ///
    /// Amazon revised their subject prefixes in 2024 to a terse `Verb: 'Item'`
    /// shape (`Ordered:`, `Shipped:`, `Arriving Sat:`, `Out for delivery:`,
    /// `Delivered:`). The legacy long-form subjects (`Your Amazon.co.uk
    /// order of...`) still show up occasionally so both styles stay matched.
    static func categorize(subject: String) -> Category {
        let s = subject.lowercased()
        if s.contains("delivered") { return .delivered }
        if s.contains("out for delivery") { return .outForDelivery }
        if s.contains("arriving")
            || s.contains("delivery update")
            || s.contains("dispatched")
            || s.contains("shipped")
            || s.contains("shipping confirmation")
            || s.contains("now expected") {
            return .arriving
        }
        if s.contains("ordered:")               // modern: "Ordered: 'Item'"
            || s.contains("order confirmation")
            || s.contains("your amazon.co.uk order")
            || s.contains("order of") {
            return .orderConfirmation
        }
        return .unknown
    }

    // MARK: Order Confirmation

    struct ParsedOrderConfirmation {
        let orderNumber: String
        let item: String
        let asin: String?
        let expectedDelivery: Date?
        let total: Double?
        let currency: String
    }

    static func parseOrderConfirmation(_ msg: MailMessage) -> ParsedOrderConfirmation? {
        let text = msg.subject + "\n" + msg.body
        guard let orderNumber = extractOrderNumber(from: text) else { return nil }
        let item = extractItem(subject: msg.subject, body: msg.body)
        let expected = extractDeliveryDate(from: msg.body)
        let total = extractTotal(from: msg.body)
        // Single-item Ordered emails still contain the per-item ASIN block,
        // so we grab the first ASIN we find for the modern format. Legacy
        // emails without that block fall through to nil.
        let asin = extractAsinAnchors(from: msg.body).first?.asin
        return ParsedOrderConfirmation(
            orderNumber: orderNumber,
            item: item,
            asin: asin,
            expectedDelivery: expected,
            total: total,
            currency: "GBP"
        )
    }

    // MARK: Delivery update (Arriving / Out for delivery / Delivered)

    struct ParsedDeliveryUpdate {
        let orderNumber: String
        let deliveryDate: Date
    }

    static func parseDeliveryUpdate(_ msg: MailMessage) -> ParsedDeliveryUpdate? {
        let text = msg.subject + "\n" + msg.body
        guard let orderNumber = extractOrderNumber(from: text) else { return nil }
        guard let date = extractDeliveryDate(from: text)
                      ?? extractDeliveryDate(from: msg.subject)
                      // Some "Out for delivery" / "Delivered" emails don't
                      // carry an explicit date in the body — assume the
                      // event happened on the email's received date.
                      ?? msg.receivedAt as Date? else { return nil }
        return ParsedDeliveryUpdate(orderNumber: orderNumber, deliveryDate: date)
    }

    // MARK: Multi-item Order Confirmation

    /// One line in a multi-item Amazon order. Mirrors the per-item block in
    /// the email body: a truncated visible name, an optional ASIN (unique id),
    /// a quantity, and an optional price (may be in pence — caller corrects
    /// via `correctPenceItemPrices`).
    ///
    /// `asin` is nil for modern plain-text Amazon UK emails that don't embed
    /// ASIN redirect URLs — in that case item name is used as the identity key.
    struct ParsedMultiItem {
        let asin: String?       // nil when the email doesn't carry ASIN URLs
        let name: String        // truncated as Amazon emails do — fine for ID
        let quantity: Int
        var price: Double?
    }

    struct ParsedMultiOrder {
        let orderNumber: String
        let items: [ParsedMultiItem]
        let expectedDelivery: Date?
        let total: Double?
        let currency: String
    }

    /// Parse an "Ordered: '...' and N more item(s)" email. We don't trust
    /// the subject for content — just for the multi-item flag. Everything
    /// else (order #, items, total, expected delivery) comes from the body.
    ///
    /// Two paths:
    ///   1. ASIN path — HTML / redirect-URL emails embed `%2Fdp%2FASIN%3F`
    ///      anchors. One note per ASIN; pence-correction applied if needed.
    ///   2. Bullet path — modern Amazon UK plain-text emails list items as
    ///      `* Item\n  Quantity: N\n  9.13 GBP` with no ASIN URLs. Items are
    ///      identified by name within the order.
    static func parseMultiOrderConfirmation(_ msg: MailMessage) -> ParsedMultiOrder? {
        let text = msg.subject + "\n" + msg.body
        guard let orderNumber = extractOrderNumber(from: text) else { return nil }
        let total = extractTotal(from: msg.body)
        let expected = extractMultiItemDeliveryDate(from: msg.body, relativeTo: msg.receivedAt)
            ?? extractDeliveryDate(from: msg.body)

        // ── Path 1: ASIN anchor URLs ──────────────────────────────────────
        let anchors = extractAsinAnchors(from: msg.body)
        if !anchors.isEmpty {
            let prices = extractItemPrices(from: msg.body)
            var items: [ParsedMultiItem] = anchors.enumerated().map { (i, anchor) in
                let price = i < prices.count ? prices[i].value : nil
                return ParsedMultiItem(asin: anchor.asin, name: anchor.name, quantity: 1, price: price)
            }
            // Pence-correction: only apply if every line-item price lacks a
            // decimal AND (no total OR sum-of-items equals total expressed in
            // pence). Belt-and-braces — protects against a discount/shipping
            // breaking the heuristic.
            let allInteger = prices.allSatisfy { !$0.hadDecimal }
            if allInteger, !prices.isEmpty {
                let sumPence = prices.reduce(0.0) { $0 + $1.value }
                let shouldCorrect: Bool = {
                    guard let t = total else { return true }
                    return (t * 100).rounded() == sumPence.rounded()
                }()
                if shouldCorrect {
                    for i in items.indices {
                        if let p = items[i].price { items[i].price = p / 100 }
                    }
                }
            }
            return ParsedMultiOrder(orderNumber: orderNumber, items: items,
                                    expectedDelivery: expected, total: total, currency: "GBP")
        }

        // ── Path 2: Plain-text bullet items (no ASINs) ───────────────────
        // Modern Amazon UK plain-text emails: "* Item\n  Quantity: 1\n  9.13 GBP"
        let bulletItems = extractPlainTextBulletItems(from: msg.body)
        guard !bulletItems.isEmpty else { return nil }
        let items: [ParsedMultiItem] = bulletItems.map {
            ParsedMultiItem(asin: nil, name: $0.name, quantity: $0.quantity, price: $0.price)
        }
        return ParsedMultiOrder(orderNumber: orderNumber, items: items,
                                expectedDelivery: expected, total: total, currency: "GBP")
    }

    /// Parse **all** order-confirmation orders in one email. Modern Amazon UK
    /// "Ordered: … and N more items" emails routinely pack *multiple* orders
    /// into a single message (each with its own `Order #`), and a single order
    /// can be split across several shipment groups (the order header repeats).
    /// We walk the body tracking the current order number and the current
    /// "Arriving …" date, tagging each `* Item` bullet to its order. Falls back
    /// to the legacy single-order (ASIN) parse when no plain-text bullets are
    /// found.
    static func parseMultiOrderConfirmations(_ msg: MailMessage) -> [ParsedMultiOrder] {
        let plain = parsePlainBulletOrders(from: msg.body, receivedAt: msg.receivedAt)
        if !plain.isEmpty { return plain }
        if let single = parseMultiOrderConfirmation(msg) { return [single] }
        return []
    }

    private static func parsePlainBulletOrders(from body: String, receivedAt: Date) -> [ParsedMultiOrder] {
        let lines = body.components(separatedBy: .newlines)

        var currentOrder: String? = nil
        var currentDate:  Date?   = nil
        var sequence: [String] = []                       // order numbers, first-seen order
        var itemsByOrder: [String: [ParsedMultiItem]] = [:]
        var dateByOrder:  [String: Date] = [:]

        func noteOrder(_ number: String) {
            currentOrder = number
            if itemsByOrder[number] == nil { sequence.append(number); itemsByOrder[number] = [] }
            if let d = currentDate, dateByOrder[number] == nil { dateByOrder[number] = d }
        }

        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // An Amazon order number — on its own line, and again in the order URL.
            if let number = firstOrderNumber(in: trimmed) {
                noteOrder(number)
                i += 1; continue
            }
            // "Arriving …" sets the delivery date for the order header that follows.
            if lower.hasPrefix("arriving") {
                currentDate = parseArrivingDate(trimmed, relativeTo: receivedAt)
                i += 1; continue
            }
            // Item bullet under the current order.
            if trimmed.hasPrefix("* "), let order = currentOrder {
                let name = cleanItemName(String(trimmed.dropFirst(2)))
                if !name.isEmpty {
                    var quantity = 1
                    var price: Double? = nil
                    var j = i + 1
                    while j < lines.count && j <= i + 5 {
                        let next = lines[j].trimmingCharacters(in: .whitespaces)
                        j += 1
                        if next.isEmpty { continue }
                        let nlower = next.lowercased()
                        if next.hasPrefix("* ") || nlower.hasPrefix("total")
                            || nlower.hasPrefix("amazon") || nlower.hasPrefix("arriving")
                            || firstOrderNumber(in: next) != nil { break }
                        if nlower.hasPrefix("quantity:"),
                           let q = Int(next.dropFirst("quantity:".count).trimmingCharacters(in: .whitespaces)) {
                            quantity = q
                        } else if let p = extractGBPAmount(from: next), price == nil {
                            price = p
                        }
                    }
                    itemsByOrder[order]?.append(ParsedMultiItem(asin: nil, name: name, quantity: quantity, price: price))
                }
            }
            i += 1
        }

        return sequence.compactMap { number in
            guard let items = itemsByOrder[number], !items.isEmpty else { return nil }
            return ParsedMultiOrder(orderNumber: number, items: items,
                                    expectedDelivery: dateByOrder[number],
                                    total: nil, currency: "GBP")
        }
    }

    /// First Amazon order number (`NNN-NNNNNNN-NNNNNNN`) appearing in a string.
    private static func firstOrderNumber(in s: String) -> String? {
        let ns = s as NSString
        guard let m = orderNumberPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    /// Resolve an "Arriving …" header to a calendar date. Handles today,
    /// tomorrow, and named weekdays (the next such weekday on/after the email
    /// date — e.g. "Arriving Friday" sent on a Tuesday → that Friday); falls
    /// back to a data-detector scan.
    static func parseArrivingDate(_ line: String, relativeTo received: Date) -> Date? {
        let cal = Calendar.current
        let lower = line.lowercased()
        if lower.contains("today")    { return cal.startOfDay(for: received) }
        if lower.contains("tomorrow") { return cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: received) ?? received) }
        let weekdays: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7)
        ]
        for (name, wd) in weekdays where lower.contains(name) {
            return nextWeekday(wd, onOrAfter: received, calendar: cal)
        }
        if let r = lower.range(of: "arriving") {
            return extractDeliveryDate(from: String(lower[r.lowerBound...]))
        }
        return nil
    }

    /// The next date with the given weekday (1 = Sunday … 7 = Saturday) on or
    /// after `date`.
    private static func nextWeekday(_ weekday: Int, onOrAfter date: Date, calendar cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        for offset in 0...7 {
            if let d = cal.date(byAdding: .day, value: offset, to: start),
               cal.component(.weekday, from: d) == weekday {
                return d
            }
        }
        return start
    }

    // MARK: Multi-item Status Update

    struct ParsedMultiStatusUpdate {
        let orderNumber: String
        let asins: [String]          // items affected by this shipment email
        let shipmentId: String?
        let date: Date               // OFD/Delivered = receivedAt; arriving = body date
    }

    /// Parse a multi-item Dispatched/OFD/Delivered email. The list of
    /// ASINs in the body is the source of truth for which items are in
    /// this particular shipment — never the subject (truncated) or the
    /// notes (a single order can span multiple shipments).
    static func parseMultiStatusUpdate(
        _ msg: MailMessage,
        category: Category
    ) -> ParsedMultiStatusUpdate? {
        let text = msg.subject + "\n" + msg.body
        guard let orderNumber = extractOrderNumber(from: text) else { return nil }
        let asins = extractAsinAnchors(from: msg.body).map { $0.asin }
        // Even with zero ASINs found (older email layout?) we still return
        // — the caller falls back to "flip all items in the order".
        let shipmentId = extractShipmentId(from: msg.body)
        let date: Date
        switch category {
        case .outForDelivery, .delivered:
            // For OFD / Delivered, the email's received date IS the event
            // date — same call we make in the single-item path.
            date = msg.receivedAt
        case .arriving:
            date = extractMultiItemDeliveryDate(from: msg.body, relativeTo: msg.receivedAt)
                ?? extractDeliveryDate(from: msg.body)
                ?? msg.receivedAt
        case .orderConfirmation, .unknown:
            return nil
        }
        return ParsedMultiStatusUpdate(
            orderNumber: orderNumber,
            asins: asins,
            shipmentId: shipmentId,
            date: date
        )
    }

    // MARK: Multi-item detection

    /// Amazon's modern multi-item subjects end with `… and N more item(s)`
    /// (with the digit and any decorative bidi marks wrapped around it).
    /// Returns the *total* item count (N + 1) when the suffix is present,
    /// or nil for single-item subjects.
    static func multiItemCount(in subject: String) -> Int? {
        let cleaned = stripBidi(subject)
        let pattern = #"(?i)\band\s+(\d+)\s+more\s+items?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m  = re.firstMatch(
                  in: cleaned,
                  range: NSRange(cleaned.startIndex..., in: cleaned)
              ),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: cleaned),
              let n = Int(cleaned[r]) else {
            return nil
        }
        return n + 1
    }

    static func isMultiItemSubject(_ subject: String) -> Bool {
        multiItemCount(in: subject) != nil
    }

    // MARK: Field extractors

    /// Strip the bidi/RTL control codepoints Amazon sprinkles around digits
    /// (`U+202B`, `U+2066`, `U+2069`, `U+200B`, `U+200E`, `U+200F`). They're
    /// invisible to the eye but break exact-match regexes.
    static func stripBidi(_ s: String) -> String {
        let bidi: Set<Character> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200B}", "\u{200E}", "\u{200F}", "\u{FEFF}"
        ]
        return String(s.unicodeScalars
            .filter { !bidi.contains(Character($0)) })
    }

    private static let orderNumberPattern = try! NSRegularExpression(
        pattern: #"\d{3}-\d{7}-\d{7}"#,
        options: []
    )

    static func extractOrderNumber(from text: String) -> String? {
        let cleaned = stripBidi(text)
        let ns = cleaned as NSString
        guard let m = orderNumberPattern.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range)
    }

    // MARK: ASIN + shipment-id + per-item blocks

    /// Amazon emails embed product URLs via a wrapped redirect: the real
    /// product URL is URL-encoded into the `U=` parameter, so an ASIN appears
    /// as `%2Fdp%2FB0CKS1CRZG%3F`. The 10-character `B0…` pattern is the
    /// conventional ASIN shape.
    private static let asinAnchorPattern = try! NSRegularExpression(
        pattern: #"<a\s+[^>]*href="[^"]*%2Fdp%2F([A-Z0-9]{10})%3F[^"]*"[^>]*>([^<]+?)</a>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Find every (asin, item name) pair in the body, in document order, one
    /// per ASIN. Two strategies because Mail.app's `content of aMsg` returns
    /// the message's text/plain part when the email is multipart/alternative
    /// (which Amazon's are) but falls back to rendered HTML when there's no
    /// plain alternative:
    ///   1. HTML anchors — quick win when we do have HTML.
    ///   2. Plain text — find ASIN URLs, walk back to the nearest line that
    ///      isn't a header / URL / price.
    static func extractAsinAnchors(from body: String) -> [(asin: String, name: String)] {
        let cleaned = stripBidi(body)

        // Strategy 1 — HTML
        let ns = cleaned as NSString
        var seen = Set<String>()
        var out: [(asin: String, name: String)] = []
        for m in asinAnchorPattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let asin = ns.substring(with: m.range(at: 1))
            let nameRaw = ns.substring(with: m.range(at: 2))
            let name = cleanItemName(nameRaw)
            guard !name.isEmpty else { continue }
            guard !seen.contains(asin) else { continue }
            seen.insert(asin)
            out.append((asin: asin, name: name))
        }
        if !out.isEmpty { return out }

        // Strategy 2 — plain text
        return extractAsinAnchorsFromPlainText(cleaned)
    }

    /// Looks for ASIN URLs (`%2Fdp%2FB0…%3F` in the encoded redirect param)
    /// and pairs each with the nearest preceding text line that isn't a
    /// known header / URL / price. Returns one entry per unique ASIN, in
    /// document order — same shape as the HTML path so callers can stay
    /// strategy-agnostic.
    private static let plainTextAsinPattern = try! NSRegularExpression(
        pattern: #"%2Fdp%2F([A-Z0-9]{10})%3F"#,
        options: []
    )

    private static let plainTextLineSkipPrefixes: [String] = [
        "Sold by", "Condition:", "Quantity:", "Order #", "Total", "Subtotal",
        "View or edit order", "Track package", "Track your order",
        "Buy Again", "Your Orders", "Your Account",
        "Please add", "Add delivery",
        "Amazon.co.uk", "©", "----", "—",
        "https://", "http://", "£", "[", "]"
    ]

    private static func extractAsinAnchorsFromPlainText(_ text: String) -> [(asin: String, name: String)] {
        let lines = text.components(separatedBy: .newlines)
        // Pre-compute the character offset where each line starts so we can
        // tell which line an NSRange falls on.
        var lineStarts: [Int] = []
        var running = 0
        for l in lines {
            lineStarts.append(running)
            running += (l as NSString).length + 1   // +1 = newline char
        }

        func lineIndex(for offset: Int) -> Int {
            // Linear scan — `lines.count` is small enough that binary
            // search isn't worth the cognitive overhead.
            var idx = 0
            for (i, s) in lineStarts.enumerated() {
                if s > offset { break }
                idx = i
            }
            return idx
        }

        let ns = text as NSString
        let matches = plainTextAsinPattern.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )

        var seen = Set<String>()
        var out: [(asin: String, name: String)] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let asin = ns.substring(with: m.range(at: 1))
            if seen.contains(asin) { continue }
            seen.insert(asin)

            let li = lineIndex(for: m.range.location)
            var i = li - 1
            while i >= 0 {
                let raw = lines[i].trimmingCharacters(in: .whitespaces)
                i -= 1
                if raw.isEmpty { continue }
                if raw.count < 3 { continue }
                if plainTextLineSkipPrefixes.contains(where: { raw.hasPrefix($0) }) { continue }
                let name = cleanItemName(raw)
                if name.isEmpty { continue }
                out.append((asin: asin, name: name))
                break
            }
        }
        return out
    }

    /// Item-name strings inside anchors come decorated with the same kinds
    /// of fluff the subject does — strip quotes, ellipses, trailing commas.
    private static func cleanItemName(_ raw: String) -> String {
        let stripChars = CharacterSet(
            charactersIn: "'\"\u{2018}\u{2019}\u{201C}\u{201D}.…, "
        )
        var s = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let before = s
            s = s.trimmingCharacters(in: stripChars)
            if s == before { break }
        }
        return s
    }

    /// The shipment id sits in the OFD/Dispatched tracking URL as
    /// `shipmentId=TV1vbnZmb`. Single value per shipment email — we capture
    /// the first occurrence.
    private static let shipmentIdPattern = try! NSRegularExpression(
        pattern: #"shipmentId=([A-Za-z0-9]+)"#,
        options: []
    )

    static func extractShipmentId(from body: String) -> String? {
        let ns = body as NSString
        guard let m = shipmentIdPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// Per-item price strings in the body are wrapped in a fixed-template
    /// `<div ...font-size:18px...>£NNN[.NN] </div>` block right after the
    /// quantity row. We pick them off in document order so they line up
    /// with `extractAsinAnchors`.
    private static let itemPricePattern = try! NSRegularExpression(
        pattern: #"font-size:18px[^>]*>\s*£\s*(\d+(?:\.\d{1,2})?)"#,
        options: [.dotMatchesLineSeparators]
    )

    static func extractItemPrices(from body: String) -> [(value: Double, hadDecimal: Bool)] {
        let cleaned = stripBidi(body)
        let ns = cleaned as NSString
        var out: [(Double, Bool)] = []
        for m in itemPricePattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: m.range(at: 1))
            guard let v = Double(raw) else { continue }
            out.append((v, raw.contains(".")))
        }
        if !out.isEmpty { return out }
        return extractItemPricesFromPlainText(cleaned)
    }

    /// Plain-text price extraction: walk the body line by line, ignoring
    /// any line that names a non-item line item (Total, Subtotal, Shipping,
    /// VAT, …) and capturing the first £-prefixed amount on each kept
    /// line. Document order is preserved so prices line up positionally
    /// with ASINs in `extractAsinAnchors`.
    private static let plainTextPricePattern = try! NSRegularExpression(
        pattern: #"£\s*(\d+(?:\.\d{1,2})?)"#,
        options: []
    )

    private static let plainTextPriceSkipPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(total|subtotal|shipping|tax|delivery charge|postage|vat|gift)\b"#,
        options: []
    )

    private static func extractItemPricesFromPlainText(_ text: String) -> [(value: Double, hadDecimal: Bool)] {
        var out: [(Double, Bool)] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let r = NSRange(location: 0, length: ns.length)
            if plainTextPriceSkipPattern.firstMatch(in: line, range: r) != nil { continue }
            if let m = plainTextPricePattern.firstMatch(in: line, range: r),
               m.numberOfRanges >= 2 {
                let raw = ns.substring(with: m.range(at: 1))
                if let v = Double(raw) {
                    out.append((v, raw.contains(".")))
                }
            }
        }
        return out
    }

    /// "Arriving today 7 am – 1 pm" / "Arriving tomorrow ..." / "Arriving
    /// Sat 23 May 7 am – 1 pm". NSDataDetector struggles with the bare
    /// "today" and "tomorrow" tokens in surrounding HTML, so we handle the
    /// two common cases explicitly. Falls back to NSDataDetector if neither
    /// token shows up.
    static func extractMultiItemDeliveryDate(from body: String, relativeTo received: Date) -> Date? {
        let cal = Calendar.current
        let lower = body.lowercased()
        if lower.contains("arriving today") {
            return cal.startOfDay(for: received)
        }
        if lower.contains("arriving tomorrow") {
            return cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: received) ?? received)
        }
        // Fallback: hunt for any date-like substring after the word "arriving".
        if let aRange = lower.range(of: "arriving") {
            let tail = String(body[aRange.lowerBound...])
            return extractDeliveryDate(from: tail)
        }
        return nil
    }

    /// Item name — best effort. Modern Amazon subjects are
    /// `Ordered: 'Item, possibly truncated...'` (curly quotes, three-dot
    /// truncation, often a trailing comma when the item name's long). We
    /// strip all that junk back to a clean string. Legacy `order of <Item>.`
    /// subjects are also handled.
    static func extractItem(subject: String, body: String) -> String {
        let stripChars = CharacterSet(
            charactersIn: "'\"\u{2018}\u{2019}\u{201C}\u{201D}.…, "
        )

        // "Verb: <Item>" — `Ordered: 'Zyliss Garlic Press Susi 4,...'`,
        // `Arriving Saturday: 'Item'`, `Shipped: 'Item'`, etc.
        if let r = subject.range(of: #"^[^:]+:\s*"#, options: .regularExpression) {
            var candidate = String(subject[r.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip all the wrappers Amazon might throw at us — applied
            // repeatedly because the stripper might unwrap one layer at a
            // time (e.g. ` '…' ` needs a quote-strip then a whitespace-strip).
            for _ in 0..<3 {
                let before = candidate
                candidate = candidate.trimmingCharacters(in: stripChars)
                if candidate == before { break }
            }
            if !candidate.isEmpty, !candidate.lowercased().contains("amazon.co.uk order") {
                return candidate
            }
        }

        // Legacy: "Your Amazon.co.uk order of <Item>."
        if let r = subject.range(of: #"order of\s+"#, options: [.regularExpression, .caseInsensitive]) {
            var candidate = String(subject[r.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasSuffix(".") { candidate.removeLast() }
            if !candidate.isEmpty {
                return candidate
            }
        }

        return "Amazon order (unparsed)"
    }

    /// Use Foundation's data detector — it handles "Saturday", "Saturday by
    /// 10pm", "Saturday, May 23", "May 23, 2026" and friends. Pick the first
    /// future-leaning date it finds.
    static func extractDeliveryDate(from text: String) -> Date? {
        let dateOnly = NSTextCheckingResult.CheckingType.date.rawValue
        guard let detector = try? NSDataDetector(types: dateOnly) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Prefer the first date that's today or in the future; fall back to
        // the first match otherwise.
        let today = Calendar.current.startOfDay(for: Date())
        for m in matches {
            if let d = m.date, d >= today.addingTimeInterval(-3600) { return d }
        }
        return matches.first?.date
    }

    private static let totalPatternPound = try! NSRegularExpression(
        pattern: #"(?i)(?:Order Total|Total|Grand Total)[:\s]*£\s*(\d+(?:\.\d{1,2})?)"#,
        options: []
    )

    /// Matches the plain-text "Total\n19.27 GBP" layout used in modern
    /// Amazon UK emails (no £ sign — just the amount and the ISO code).
    private static let totalPatternGBP = try! NSRegularExpression(
        pattern: #"(?i)(?:Order Total|Total|Grand Total)\s*\n\s*(\d+(?:\.\d{1,2})?)\s+GBP"#,
        options: []
    )

    static func extractTotal(from text: String) -> Double? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = totalPatternPound.firstMatch(in: text, range: range),
           m.numberOfRanges >= 2 {
            return Double(ns.substring(with: m.range(at: 1)))
        }
        if let m = totalPatternGBP.firstMatch(in: text, range: range),
           m.numberOfRanges >= 2 {
            return Double(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    // MARK: Plain-text bullet item extraction

    /// Extract a sterling amount from a single trimmed line.
    /// Handles "£9.13" and "9.13 GBP" (the format used in modern Amazon
    /// UK plain-text emails).
    static func extractGBPAmount(from line: String) -> Double? {
        let t = line.trimmingCharacters(in: .whitespaces)
        // "9.13 GBP"
        if t.hasSuffix(" GBP") {
            let s = String(t.dropLast(4)).trimmingCharacters(in: .whitespaces)
            if let v = Double(s) { return v }
        }
        // "£9.13"
        if t.hasPrefix("£") {
            let s = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let v = Double(s) { return v }
        }
        return nil
    }

    /// Parse items from the plain-text bullet format that modern Amazon UK
    /// order emails use when they don't embed ASIN redirect URLs:
    ///
    ///   * Item Name
    ///     Quantity: 1
    ///     9.13 GBP
    ///
    /// Returns items in document order. Price is optional — some items may
    /// not have a parseable price line.
    static func extractPlainTextBulletItems(from body: String) -> [(name: String, quantity: Int, price: Double?)] {
        let lines = body.components(separatedBy: .newlines)
        var out: [(name: String, quantity: Int, price: Double?)] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* ") else { i += 1; continue }
            let name = cleanItemName(String(trimmed.dropFirst(2)))
            guard !name.isEmpty else { i += 1; continue }
            var quantity = 1
            var price: Double? = nil
            // Scan ahead up to 5 lines for Quantity: and price.
            var j = i + 1
            while j < lines.count && j <= i + 5 {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                j += 1
                if next.isEmpty { continue }
                // Stop at the next bullet item.
                if next.hasPrefix("* ") { break }
                // Stop at summary / footer lines.
                let lower = next.lowercased()
                if lower.hasPrefix("total") || lower.hasPrefix("amazon") { break }
                if lower.hasPrefix("quantity:"),
                   let q = Int(next.dropFirst("Quantity:".count).trimmingCharacters(in: .whitespaces)) {
                    quantity = q
                } else if let p = extractGBPAmount(from: next), price == nil {
                    price = p
                }
            }
            out.append((name: name, quantity: quantity, price: price))
            i += 1
        }
        return out
    }
}

// MARK: - Note builder

private enum AmazonNoteBuilder {

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func write(
        confirmation: AmazonEmailParser.ParsedOrderConfirmation,
        message: MailMessage,
        in folder: URL
    ) throws -> URL {
        let dateStr = isoFormatter.string(from: message.receivedAt)
        let safeItem = sanitizeForFilename(confirmation.item)
        let stem = "\(dateStr) Amazon - \(safeItem)"
        var url = folder.appendingPathComponent("\(stem).md")

        // Suffix-collision: if a file with this exact name exists (different
        // order), append the order suffix.
        if FileManager.default.fileExists(atPath: url.path) {
            let suffix = confirmation.orderNumber.suffix(7)
            url = folder.appendingPathComponent("\(stem) (\(suffix)).md")
        }

        // Build YAML frontmatter, only writing fields we have values for.
        var lines: [String] = []
        lines.append("vendor: Amazon")
        lines.append("item: \(Self.colonSafe(confirmation.item))")
        lines.append("order_number: \(confirmation.orderNumber)")
        lines.append("order_date: \(isoFormatter.string(from: message.receivedAt))")
        lines.append("status: order-confirmed")
        let trackingURL = "https://www.amazon.co.uk/your-orders/order-details?orderID=\(confirmation.orderNumber)"
        lines.append("tracking_url: \(trackingURL)")
        if let expected = confirmation.expectedDelivery {
            lines.append("expected_delivery: \(isoFormatter.string(from: expected))")
        }
        if let total = confirmation.total {
            lines.append("total: \(total)")
        }
        lines.append("currency: \(confirmation.currency)")
        let emailURL = buildMessageURL(for: message.messageID)
        lines.append("email_url: \(emailURL)")
        if let asin = confirmation.asin {
            lines.append("asin: \(asin)")
        }

        var content = "---\n"
        content += lines.joined(separator: "\n")
        content += "\n---\n\n"
        content += "# Amazon — \(confirmation.item)\n"

        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Build one note per item in a multi-item Amazon order. All items
    /// share the same `order_number`, `order_date`, and (per-item) tracking
    /// URL; each note gets its own ASIN, name, and price. Skips items that
    /// already have a note (matched on order_number + asin).
    /// Returns the created file URLs in input order.
    static func writeMultiItem(
        order: AmazonEmailParser.ParsedMultiOrder,
        message: MailMessage,
        existing: [Delivery],
        in folder: URL
    ) throws -> [(url: URL, item: AmazonEmailParser.ParsedMultiItem)] {
        let dateStr = isoFormatter.string(from: message.receivedAt)
        let trackingURL = "https://www.amazon.co.uk/your-orders/order-details?orderID=\(order.orderNumber)"
        let emailURL = buildMessageURL(for: message.messageID)
        let orderSuffix = String(order.orderNumber.suffix(7))

        var written: [(URL, AmazonEmailParser.ParsedMultiItem)] = []
        for item in order.items {
            // Dedup: use (order_number, asin) when an ASIN is available —
            // that's the canonical per-item primary key. Fall back to
            // (order_number, normalised item name) for plain-text emails
            // that don't carry ASIN URLs, so a re-scan doesn't create
            // duplicates even without a unique identifier on each item.
            let isDuplicate: Bool
            if let itemAsin = item.asin {
                isDuplicate = existing.contains(where: {
                    $0.orderNumber == order.orderNumber && $0.asin == itemAsin
                })
            } else {
                // Normalise BOTH sides through colonSafe so a parsed name that
                // still has its colon ("Curry Guy Thai: …") matches a stored
                // note that's been de-coloned ("Curry Guy Thai - …") — otherwise
                // a colon-bearing item would dodge dedup and be duplicated.
                let normName = Self.colonSafe(item.name).lowercased().trimmingCharacters(in: .whitespaces)
                isDuplicate = existing.contains(where: {
                    $0.orderNumber == order.orderNumber
                        && Self.colonSafe($0.item).lowercased().trimmingCharacters(in: .whitespaces) == normName
                })
            }
            if isDuplicate { continue }

            let safeItem = sanitizeForFilename(item.name)
            // Disambiguate from sibling items in the same order by always
            // appending the order suffix on the multi-item path. Avoids
            // any collision between two items with identical sanitised
            // prefixes (e.g. both truncate to the same string).
            let stem = "\(dateStr) Amazon - \(safeItem) (\(orderSuffix))"
            var url = folder.appendingPathComponent("\(stem).md")
            if FileManager.default.fileExists(atPath: url.path) {
                // Last-ditch disambiguator if the filename collides on disk
                // (shouldn't happen in practice). Use ASIN if available,
                // otherwise a hash of the item name.
                let disambig = item.asin ?? String(abs(item.name.hashValue), radix: 36)
                url = folder.appendingPathComponent("\(stem) \(disambig).md")
            }

            var lines: [String] = []
            lines.append("vendor: Amazon")
            lines.append("item: \(Self.colonSafe(item.name))")
            lines.append("order_number: \(order.orderNumber)")
            lines.append("order_date: \(isoFormatter.string(from: message.receivedAt))")
            lines.append("status: order-confirmed")
            lines.append("tracking_url: \(trackingURL)")
            if let expected = order.expectedDelivery {
                lines.append("expected_delivery: \(isoFormatter.string(from: expected))")
            }
            if let price = item.price {
                // Amazon's plain-text emails show the UNIT price next to
                // "Quantity: N"; the note's `total` is the line total, so
                // multiply through (e.g. Galvog 8.49 × 2 = 16.98).
                lines.append("total: \(Self.money(price * Double(item.quantity)))")
            }
            lines.append("currency: \(order.currency)")
            lines.append("quantity: \(item.quantity)")
            lines.append("email_url: \(emailURL)")
            if let asin = item.asin {
                lines.append("asin: \(asin)")
            }

            var content = "---\n"
            content += lines.joined(separator: "\n")
            content += "\n---\n\n"
            content += "# Amazon — \(item.name)\n"

            try content.write(to: url, atomically: true, encoding: .utf8)
            written.append((url, item))
        }
        return written
    }

    /// Build a `message://<id>` URL Mail.app will open. RFC822 IDs are
    /// typically `<random@host>` — URL-encode the angle brackets.
    private static func buildMessageURL(for messageID: String) -> String {
        let cleaned = messageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleaned
        return "message://%3C\(encoded)%3E"
    }

    /// Make a string safe to write as an UNQUOTED YAML scalar by removing
    /// colons: a colon-space (`: `) in an unquoted value makes the whole
    /// frontmatter invalid YAML and the note silently vanishes from OhDelhi
    /// (book titles like "Fantastic Kingdom: A Stranger's Notes…" are the
    /// usual offenders). Replacing the colon with a dash is durable — unlike
    /// quoting, a later rewrite can't undo it.
    static func colonSafe(_ s: String) -> String {
        s.replacingOccurrences(of: ": ", with: " - ")
         .replacingOccurrences(of: ":", with: "-")
    }

    /// Format a sterling amount the way the notes do: two decimals, with any
    /// trailing zeros (and a bare dot) trimmed — 41.00 → "41", 16.98 → "16.98".
    static func money(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Strip macOS-illegal filename characters; collapse runs of whitespace.
    private static func sanitizeForFilename(_ raw: String) -> String {
        var s = raw
        // Forward slash and colon are illegal in filenames on macOS.
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: ":", with: "-")
        // Collapse newlines and tabs.
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        // Trim to a reasonable length (HFS/APFS support 255 bytes but long
        // names get awkward in Finder).
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 {
            return String(trimmed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

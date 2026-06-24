//
//  DeliveryStore.swift
//  OhDelhi
//
//  Observable store. Polls the `03.10 Deliveries/` folder every 5s and mirrors
//  the on-disk `.md` files into an in-memory `[Delivery]`.
//
//  Same pattern Oatly and Ommediate use — Timer polling rather than FSEvents,
//  because content-only edits to existing files don't fire file-system events
//  reliably.
//

import Foundation
import Observation

@Observable
final class DeliveryStore {

    // ---- Public state ------------------------------------------------------

    private(set) var deliveries: [Delivery] = []
    private(set) var lastLoad: Date? = nil
    private(set) var lastError: String? = nil

    /// Last successful write to `iCloud.com.davidturnbull.ohdelhi/Documents/deliveries.json`.
    private(set) var lastiCloudWrite: Date? = nil

    /// Last iCloud write failure message (nil after a successful write).
    private(set) var lastiCloudError: String? = nil

    /// Number of deliveries in the most recently written snapshot.
    private(set) var lastiCloudDeliveryCount: Int = 0

    /// User-facing override that allows iCloud writes from a non-canonical
    /// machine (e.g. the laptop) for testing — same pattern as Ommediate.
    var iCloudSyncOverride: Bool {
        didSet { UserDefaults.standard.set(iCloudSyncOverride, forKey: Self.overrideKey) }
    }

    /// Sync gate: write the snapshot on the always-on Mac unconditionally, or
    /// anywhere the override is on.
    var iCloudSyncEnabled: Bool { isCanonicalHost || iCloudSyncOverride }

    /// True when running on the always-on machine — toggle is locked on there.
    var isCanonicalHost: Bool {
        ProcessInfo.processInfo.hostName == Self.canonicalHostname
    }

    /// Absolute path to the `03.10 Deliveries/` folder. Persisted in UserDefaults.
    var deliveriesFolder: String {
        didSet {
            UserDefaults.standard.set(deliveriesFolder, forKey: Self.foldKey)
            reload()
        }
    }

    // ---- Init / lifecycle --------------------------------------------------

    private static let foldKey           = "OhDelhi.deliveriesFolder"
    private static let overrideKey       = "OhDelhi.iCloudSyncOverride"
    private static let canonicalHostname = "MMUtil.local"
    private static let iCloudContainerID = "iCloud.com.davidturnbull.ohdelhi"
    private static let snapshotFilename  = "deliveries.json"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.foldKey)
        self.deliveriesFolder = stored ?? Self.defaultDeliveriesFolder
        self.iCloudSyncOverride = UserDefaults.standard.bool(forKey: Self.overrideKey)
        startPolling()
        reload()
    }

    /// Best-guess default. Works on David's machine out of the box.
    private static var defaultDeliveriesFolder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Documents/DTObs/00-09 DTOS/03 Working Folders/03.10 Deliveries")
            .path(percentEncoded: false)
    }

    // ---- Polling -----------------------------------------------------------

    private var timer: Timer?

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    // ---- Reload ------------------------------------------------------------

    func reload() {
        let folder = URL(fileURLWithPath: deliveriesFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            self.lastError = "Folder not found: \(folder.path)"
            self.deliveries = []
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }
            let parsed: [Delivery] = mdFiles.compactMap { DeliveryParser.parse(fileURL: $0) }

            // Default sort: by sortDate ascending (earliest first; confirmed
            // delivery date trumps expected — see `Delivery.targetDate`), then
            // by carrier (alphabetical, missing-carriers last), then vendor +
            // item for stability when both date and carrier match.
            let sorted = parsed.sorted(by: Self.byDateThenCarrier)

            // Apply any `mobile_edit` instructions the phone wrote. This edits
            // the notes on disk and schedules a follow-up reload, so the
            // applied values surface on the next pass.
            applyMobileEditsIfAny(sorted)

            // Detect status transitions BEFORE replacing `self.deliveries` so
            // the comparison sees both "before" and "after". Skipped on first
            // load to avoid firing side effects retroactively for whatever is
            // already on disk at launch.
            applyTransitionSideEffectsIfAny(newDeliveries: sorted)

            self.deliveries = sorted
            self.lastLoad = Date()
            self.lastError = nil

            writeSnapshotToiCloudIfNeeded()
        } catch {
            self.lastError = "Reload failed: \(error.localizedDescription)"
        }
    }

    // ---- Filtering --------------------------------------------------------

    /// Apply a smart filter to the current set. The same parcel may pass
    /// multiple filters (e.g. an overdue parcel is also "all expected").
    ///
    /// Sort policy:
    /// - `.today` and `.tomorrow` — re-sort by carrier alone, since every item
    ///   in those slices shares the same target date and date-sort would be
    ///   noise.
    /// - everything else — keep the store's default `byDateThenCarrier` order.
    func deliveries(for filter: SmartFilter) -> [Delivery] {
        let pool: [Delivery]
        switch filter {
        case .today:
            pool = deliveries.filter { $0.isDueToday }
        case .tomorrow:
            pool = deliveries.filter { $0.isDueTomorrow }
        case .thisWeek:
            pool = deliveries.filter { $0.isThisWeek }
        case .overdue:
            pool = deliveries.filter { $0.isOverdue }
        case .allExpected:
            pool = deliveries.filter { $0.status.isExpected }
                .sorted { a, b in
                    // Sort by targetDate (confirmed → expected) only.
                    // Falls back to orderDate as tiebreaker, nil → bottom.
                    let at = a.targetDate ?? .distantFuture
                    let bt = b.targetDate ?? .distantFuture
                    if at != bt { return at < bt }
                    // Items with no target date: sort by orderDate, nil last
                    if a.targetDate == nil && b.targetDate == nil {
                        let ao = a.orderDate ?? .distantFuture
                        let bo = b.orderDate ?? .distantFuture
                        if ao != bo { return ao < bo }
                    }
                    return Self.byCarrier(a, b)
                }
        case .recentlyDelivered:
            let cal = Calendar.current
            let cutoff = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? .distantPast
            pool = deliveries.filter { d in
                guard d.status == .delivered else { return false }
                guard let when = d.confirmedDelivery ?? d.expectedDelivery else { return false }
                return when >= cutoff
            }
        }

        switch filter {
        case .today, .tomorrow:
            return pool.sorted(by: Self.byCarrier)
        default:
            return pool   // already in byDateThenCarrier order
        }
    }

    func deliveries(forStatus status: DeliveryStatus) -> [Delivery] {
        deliveries.filter { $0.status == status }
    }

    func count(for filter: SmartFilter) -> Int { deliveries(for: filter).count }
    func count(forStatus status: DeliveryStatus) -> Int { deliveries(forStatus: status).count }

    // ---- Sort comparators -------------------------------------------------

    /// Primary sort: target date asc → carrier asc (nil last) → vendor → item.
    private static func byDateThenCarrier(_ a: Delivery, _ b: Delivery) -> Bool {
        let ad = a.sortDate ?? .distantFuture
        let bd = b.sortDate ?? .distantFuture
        if ad != bd { return ad < bd }
        return byCarrier(a, b)
    }

    /// Carrier-first sort: carrier asc (nil last) → vendor → item.
    /// Used as-is for the Today/Tomorrow filters where date is a constant.
    private static func byCarrier(_ a: Delivery, _ b: Delivery) -> Bool {
        // Push missing carriers to the end. `~` sorts after all printable
        // ASCII letters in case-insensitive comparison.
        let ac = a.carrier?.lowercased() ?? "~"
        let bc = b.carrier?.lowercased() ?? "~"
        if ac != bc { return ac < bc }
        if a.vendor.localizedCaseInsensitiveCompare(b.vendor) != .orderedSame {
            return a.vendor.localizedCaseInsensitiveCompare(b.vendor) == .orderedAscending
        }
        return a.item.localizedCaseInsensitiveCompare(b.item) == .orderedAscending
    }

    // ---- Transition detector ----------------------------------------------

    /// Per-file last-observed status, keyed by fileURL. Compared against the
    /// latest reload to detect status changes the iPhone made via Advanced
    /// URI — those changes only flip the `status` field and rely on the Mac
    /// to stamp `confirmed_delivery` and write the daily-note line.
    ///
    /// Empty on first load — we don't fire side effects retroactively for
    /// whatever statuses are on disk at launch. So if the iPhone made a change
    /// while the Mac was off, the daily-note line won't be backfilled on the
    /// next Mac launch. Acceptable v1 limitation, same as Ommediate.
    private var observedStatuses: [URL: DeliveryStatus] = [:]

    // ---- Mobile edit processor --------------------------------------------

    /// Apply any pending `mobile_edit` instructions written by OhDelhiMobile.
    /// iOS can only fire one Advanced URI per action, so the phone packs all
    /// changed fields into a single `mobile_edit` string; the always-on Mac
    /// fans it out to the real frontmatter fields. Format: `;;`-delimited
    /// `key=value` pairs, keys `carrier` / `expected` / `tracking`. An empty
    /// value clears that field. After applying, the `mobile_edit` line is
    /// removed and a follow-up reload is scheduled so the snapshot reflects
    /// the new values promptly.
    private func applyMobileEditsIfAny(_ deliveries: [Delivery]) {
        var appliedAny = false
        for delivery in deliveries {
            guard let raw = delivery.mobileEdit?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            applyMobileEdit(raw, to: delivery.fileURL)
            appliedAny = true
        }
        if appliedAny {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    private func applyMobileEdit(_ raw: String, to fileURL: URL) {
        for pair in raw.components(separatedBy: ";;") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key   = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...])   // may be empty → clear
            let frontmatterKey: String
            switch key {
            case "carrier":  frontmatterKey = "carrier"
            case "expected": frontmatterKey = "expected_delivery"
            case "tracking": frontmatterKey = "tracking_number"
            default: continue
            }
            try? NoteEditor.setField(frontmatterKey, to: value.isEmpty ? nil : value, in: fileURL)
        }
        // Clear the instruction so it isn't applied again on the next poll.
        try? NoteEditor.removeField("mobile_edit", in: fileURL)
    }

    // ---- Transition detector ----------------------------------------------

    private func applyTransitionSideEffectsIfAny(newDeliveries: [Delivery]) {
        defer {
            observedStatuses = Dictionary(uniqueKeysWithValues:
                newDeliveries.map { ($0.fileURL, $0.status) }
            )
        }

        // First load — populate but don't fire effects.
        guard !observedStatuses.isEmpty else { return }

        for delivery in newDeliveries {
            guard let oldStatus = observedStatuses[delivery.fileURL] else { continue }
            guard oldStatus != delivery.status else { continue }
            applyTransitionSideEffects(delivery, from: oldStatus, to: delivery.status)
        }
    }

    /// Side effects for a single status transition. Currently only the
    /// →delivered case (the one action the iPhone can drive). Mirrors
    /// `DeliveryDetailView.markReceived` but with idempotency checks so it's
    /// safe to run repeatedly across reloads and alongside the Mac UI path.
    private func applyTransitionSideEffects(_ delivery: Delivery, from oldStatus: DeliveryStatus, to newStatus: DeliveryStatus) {
        guard newStatus == .delivered else { return }

        do {
            // Stamp confirmed_delivery to today only if currently empty — the
            // user (or a tracker) might have set a sharper date already.
            if delivery.confirmedDelivery == nil {
                try NoteEditor.setTodayDate("confirmed_delivery", in: delivery.fileURL)
            }

            // Daily-note DELIVERED line, deduped per stem so the Mac UI path
            // and this detector can't double-log the same parcel.
            let stem  = delivery.fileURL.deletingPathExtension().lastPathComponent
            let time  = NoteEditor.currentTimeHHMM()
            let line  = "- *\(time)* - DELIVERED: [[\(stem)]]"
            let dedup = "DELIVERED: [[\(stem)]]"
            _ = try? NoteEditor.appendToDailyNote(line, dedupeOn: dedup)
        } catch {
            // Swallow — never roll back a status change because the daily note
            // or confirmed-date write failed.
            print("Delivered transition side effects failed for \(delivery.item): \(error)")
        }
    }

    // ---- iCloud snapshot writer --------------------------------------------

    /// Cached bytes of the last successfully written deliveries array. Lets us
    /// skip no-op writes when nothing relevant has changed.
    private var lastWrittenSnapshotBytes: Data?

    /// Write a JSON snapshot of the mobile-relevant deliveries — status
    /// `order-confirmed`, `shipped`, or `out-for-delivery` — to the iCloud
    /// container. No-op when the sync gate is closed, the container is
    /// unavailable, or the payload is byte-identical to the last successful
    /// write.
    private func writeSnapshotToiCloudIfNeeded() {
        guard iCloudSyncEnabled else { return }

        guard let containerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: Self.iCloudContainerID
        ) else {
            lastiCloudError = "iCloud container unavailable — is iCloud Drive on, and the capability set on the target?"
            return
        }

        let mobileDeliveries = deliveries.filter {
            $0.status == .orderConfirmed || $0.status == .shipped || $0.status == .outForDelivery
        }

        let vaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DTObs")
            .path(percentEncoded: false)

        let payload = DeliveriesPayload(
            deliveries: mobileDeliveries.map { delivery in
                delivery.toJSON(vaultRelativePath: Self.vaultRelativePath(for: delivery.fileURL, vaultRoot: vaultRoot))
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]

        // Diff on the deliveries array alone (writtenAt is re-baked each call).
        let bookBytes: Data = (try? encoder.encode(payload.deliveries)) ?? Data()
        if let prev = lastWrittenSnapshotBytes, prev == bookBytes {
            return
        }

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            lastiCloudError = "Snapshot encode failed: \(error.localizedDescription)"
            return
        }

        do {
            let docs = containerURL.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let file = docs.appendingPathComponent(Self.snapshotFilename)
            try data.write(to: file, options: .atomic)
            lastWrittenSnapshotBytes = bookBytes
            lastiCloudWrite          = Date()
            lastiCloudDeliveryCount  = mobileDeliveries.count
            lastiCloudError          = nil
        } catch {
            lastiCloudError = "Snapshot write failed: \(error.localizedDescription)"
        }
    }

    /// Convert a full vault file URL into the path Obsidian Advanced URI wants
    /// for `filepath=` (relative to vault root). Tolerates a `vaultRoot` with
    /// or without a trailing slash.
    static func vaultRelativePath(for url: URL, vaultRoot: String) -> String {
        let full = url.path(percentEncoded: false)
        let normalisedRoot: String = {
            var r = vaultRoot
            while r.hasSuffix("/") { r.removeLast() }
            return r + "/"
        }()
        if full.hasPrefix(normalisedRoot) {
            return String(full.dropFirst(normalisedRoot.count))
        }
        return full
    }
}

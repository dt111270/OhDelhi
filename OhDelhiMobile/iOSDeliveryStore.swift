//
//  iOSDeliveryStore.swift
//  OhDelhiMobile
//
//  Reads the deliveries.json snapshot written by the Mac into
//  iCloud.com.davidturnbull.ohdelhi/Documents/deliveries.json. Decodes
//  `DeliveriesPayload` (shared with the Mac target via
//  DeliverySnapshot.swift) and publishes the in-flight deliveries for
//  SwiftUI.
//
//  The only writeback is "Mark as Delivered", which fires a single Advanced
//  URI flipping `status` to `delivered`. The Mac's DeliveryStore detects the
//  transition on its next poll and applies the side effects
//  (confirmed_delivery stamp, daily-note DELIVERED line) idempotently. This
//  keeps the iOS side reliable on iOS's "URL open backgrounds the calling
//  app" semantic.
//
//  Round-trip latency note (June 2026): the path back is phone edit →
//  Obsidian Sync → Mac vault → OhDelhi poll → snapshot rewrite → iCloud →
//  phone. Obsidian Sync alone can take minutes, so a marked parcel stays
//  hidden until the snapshot itself confirms the Mac has processed it —
//  not for a fixed few seconds. See `pendingTransitions`.
//

import Foundation
import Observation

@Observable
final class iOSDeliveryStore {

    // ---- Public state ------------------------------------------------------

    private(set) var deliveries: [DeliveryJSON] = []
    private(set) var lastLoad:   Date?          = nil
    private(set) var lastError:  String?        = nil

    /// Schema mismatch detected on last load. Surfaces in the UI so we tell
    /// the user to update the app rather than silently showing stale data.
    private(set) var snapshotSchemaMismatch: Bool = false

    /// Deliveries whose mark-as-delivered has been fired but hasn't round-
    /// tripped back into the snapshot yet, keyed by delivery ID with the time
    /// the URI was fired. Filtered out of `inFlight` so the parcel disappears
    /// immediately and STAYS hidden while Obsidian Sync + the Mac catch up
    /// (which can take minutes, not seconds).
    ///
    /// An entry is cleared when:
    ///   • a freshly loaded snapshot no longer contains the ID — the Mac has
    ///     processed the transition and rewritten the snapshot (success), or
    ///   • `pendingTransitionTimeout` elapses — the write probably never
    ///     landed, so the parcel resurfaces for a retry (failure).
    ///
    /// Persisted to UserDefaults so backgrounding or relaunching the app —
    /// which the Advanced URI hand-off to Obsidian makes near-certain —
    /// doesn't resurrect parcels that are still mid-round-trip.
    private(set) var pendingTransitions: [String: Date] = [:]

    /// Generous fallback: Obsidian Sync routinely takes several minutes to
    /// carry the phone's edit to the Mac. Only after this long do we assume
    /// the write failed and restore the row.
    private static let pendingTransitionTimeout: TimeInterval = 30 * 60

    private static let pendingKey = "OhDelhiMobile.pendingTransitions"

    // ---- The list the UI shows ---------------------------------------------

    /// Everything in the snapshot (the Mac only ever sends order-confirmed /
    /// shipped / out-for-delivery), soonest first, minus anything we've just
    /// marked.
    var inFlight: [DeliveryJSON] {
        deliveries
            .filter { pendingTransitions[$0.id] == nil }
            .sorted { $0.sortDate < $1.sortDate }
    }

    // ---- Init / config -----------------------------------------------------

    /// iCloud container identifier — must match the one set in the Signing &
    /// Capabilities tab for both the Mac and iOS targets.
    private static let iCloudContainerID = "iCloud.com.davidturnbull.ohdelhi"
    private static let snapshotFilename  = "deliveries.json"

    init() {
        loadPendingTransitions()
        load()
    }

    // ---- Read --------------------------------------------------------------

    /// Outcome of a background snapshot fetch. Carries just enough for the
    /// `@MainActor` `apply` step to set the right state and error text —
    /// keeping all the user-facing message strings in one place (`apply`).
    private enum LoadOutcome {
        case success([DeliveryJSON])
        case schemaMismatch(Int)
        case containerUnavailable
        case noFile
        case readFailed(String)
    }

    /// Refresh the snapshot from iCloud. Returns immediately — the file read
    /// and decode run on a background task and the result is published back on
    /// the main actor via `apply`. Safe to call repeatedly.
    ///
    /// Kept off the main thread defensively: a read from a ubiquitous container
    /// can occasionally fault in the file, and doing any of that on the main
    /// thread risks stalling the UI at launch.
    func load() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.fetchSnapshot()
            await self?.apply(outcome)
        }
    }

    /// Resolve the container, perform the blocking coordinated read, and
    /// decode — all off the main thread. Uses only static state so it can run
    /// nonisolated.
    private nonisolated static func fetchSnapshot() -> LoadOutcome {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: iCloudContainerID
        ) else {
            return .containerUnavailable
        }

        let file = container
            .appendingPathComponent("Documents")
            .appendingPathComponent(snapshotFilename)

        do {
            let data    = try readLatestSnapshotData(at: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(DeliveriesPayload.self, from: data)

            guard payload.schema == DeliveriesPayload.currentSchema else {
                return .schemaMismatch(payload.schema)
            }
            return .success(payload.deliveries)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .noFile
        } catch {
            return .readFailed(error.localizedDescription)
        }
    }

    /// Publish a fetch result. Runs on the main actor so it can safely mutate
    /// the observable state the UI reads.
    @MainActor
    private func apply(_ outcome: LoadOutcome) {
        switch outcome {
        case .success(let fetched):
            self.deliveries             = fetched
            self.lastLoad               = Date()
            self.lastError              = nil
            self.snapshotSchemaMismatch = false
            // Only prune against a snapshot we actually decoded — an error
            // path must never clear pending entries en masse.
            prunePendingTransitions(against: fetched)

        case .schemaMismatch(let schema):
            snapshotSchemaMismatch = true
            deliveries = []   // don't show stale data behind the mismatch warning
            lastError = "Snapshot schema \(schema) doesn't match the version this app expects (\(DeliveriesPayload.currentSchema)). Update OhDelhiMobile."

        case .containerUnavailable:
            lastError = "iCloud container unavailable. Check that iCloud Drive is on for this device and the iCloud capability is set on the OhDelhiMobile target."

        case .noFile:
            lastError = "No snapshot found yet — open OhDelhi on the Mac to write the first one, then wait a moment for iCloud to sync."
            deliveries = []

        case .readFailed(let message):
            lastError = "Failed to read snapshot: \(message)"
        }
    }

    /// Read the snapshot bytes. A plain `Data(contentsOf:)`, exactly as the
    /// proven OmmediateMobile sibling does it.
    ///
    /// History (June 2026): this previously used `startDownloadingUbiquitousItem`
    /// + a synchronous `NSFileCoordinator` coordinated read, to guarantee the
    /// freshest copy rather than iCloud's local cache. That code had never run
    /// on a device until it was first built — and when it did, the coordination/
    /// XPC machinery crashed the app on launch (`-[OS_dispatch_mach_msg
    /// _setContext:]: unrecognized selector`, an async libdispatch abort with no
    /// app frames in the backtrace). It's not worth it: the "don't let a marked
    /// parcel reappear before the Mac confirms it" guarantee is already provided
    /// by `pendingTransitions`, and iCloud updates the local cached file on its
    /// own, so the next foreground/refresh picks up the Mac's rewrite anyway.
    private nonisolated static func readLatestSnapshotData(at file: URL) throws -> Data {
        try Data(contentsOf: file)
    }

    // ---- Writeback ---------------------------------------------------------

    /// Mark a delivery as delivered. Fires a single status-change URI; the
    /// Mac's transition detector handles the confirmed_delivery stamp and
    /// the daily-note DELIVERED line.
    @MainActor
    func markAsDelivered(_ delivery: DeliveryJSON) {
        // Optimistic: hide it immediately. It stays hidden until the Mac's
        // rewritten snapshot confirms the round-trip (the ID disappears), or
        // until the fallback timeout restores it so the user can retry.
        pendingTransitions[delivery.id] = Date()
        savePendingTransitions()

        AdvancedURI.setFrontmatter(filepath: delivery.id, key: "status", value: "delivered")

        // Belt-and-braces UI refresh if the app happens to stay foregrounded
        // past the timeout — prune-on-load covers every other path.
        let id = delivery.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingTransitionTimeout))
            await MainActor.run {
                guard let self, let fired = self.pendingTransitions[id] else { return }
                if Date().timeIntervalSince(fired) >= Self.pendingTransitionTimeout {
                    self.pendingTransitions.removeValue(forKey: id)
                    self.savePendingTransitions()
                }
            }
        }
    }

    // ---- Pending-transition persistence -------------------------------------

    /// Drop entries the Mac has confirmed (ID gone from a fresh snapshot) or
    /// that have outlived the fallback timeout.
    private func prunePendingTransitions(against snapshot: [DeliveryJSON]) {
        guard !pendingTransitions.isEmpty else { return }

        let snapshotIDs = Set(snapshot.map(\.id))
        let now = Date()
        let pruned = pendingTransitions.filter { id, fired in
            snapshotIDs.contains(id) &&
            now.timeIntervalSince(fired) < Self.pendingTransitionTimeout
        }

        if pruned != pendingTransitions {
            pendingTransitions = pruned
            savePendingTransitions()
        }
    }

    private func loadPendingTransitions() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.pendingKey) else { return }
        let now = Date()
        pendingTransitions = stored.compactMapValues { $0 as? Date }
            .filter { now.timeIntervalSince($0.value) < Self.pendingTransitionTimeout }
    }

    private func savePendingTransitions() {
        UserDefaults.standard.set(pendingTransitions, forKey: Self.pendingKey)
    }
}

//
//  SettingsView.swift
//  OhDelhi
//
//  Cmd-, opens this. Vault folder, tracking sync providers, diagnostics.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(DeliveryStore.self)     private var store
    @Environment(RoyalMailTracker.self)  private var rmTracker
    @Environment(AmazonMailTracker.self) private var amzTracker
    @Environment(DHLTracker.self)        private var dhlTracker
    @Environment(FedExTracker.self)      private var fedexTracker
    @Environment(ParcelTracker.self)     private var parcelTracker

    @State private var draftFolder: String = ""

    var body: some View {
        @Bindable var store         = store
        @Bindable var rmTracker     = rmTracker
        @Bindable var amzTracker    = amzTracker
        @Bindable var dhlTracker    = dhlTracker
        @Bindable var fedexTracker  = fedexTracker
        @Bindable var parcelTracker = parcelTracker

        Form {
            Section("Deliveries Folder") {
                LabeledContent("Path") {
                    HStack {
                        TextField("Path", text: $draftFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { pickFolder() }
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply") {
                        store.deliveriesFolder = draftFolder
                    }
                    .disabled(draftFolder == store.deliveriesFolder)
                }

                LabeledContent("Deliveries", value: "\(store.deliveries.count)")
                if let last = store.lastLoad {
                    LabeledContent("Last reload", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last reload", value: "never")
                }
                if let err = store.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Section("Mobile Sync (iCloud → OhDelhiMobile)") {
                if store.isCanonicalHost {
                    LabeledContent("Sync", value: "On (always-on Mac)")
                } else {
                    Toggle("Write snapshot from this Mac", isOn: $store.iCloudSyncOverride)
                    Text("Off by default on non-canonical machines. Turn on to test the iPhone app from this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Snapshot deliveries", value: "\(store.lastiCloudDeliveryCount)")
                if let last = store.lastiCloudWrite {
                    LabeledContent("Last write", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last write", value: "never")
                }
                if let err = store.lastiCloudError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text("Snapshots order-confirmed, shipped, and out-for-delivery parcels. The phone can Track or Mark as Delivered; the Mark flows back here and stamps confirmed_delivery + logs the daily note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Royal Mail Tracking (via texts + Mail.app)") {
                Toggle("Enable periodic scan (every 15 min)", isOn: $rmTracker.isEnabled)
                Toggle("Also scan Mail.app for RM emails", isOn: $rmTracker.emailScanEnabled)
                Text("Scans the same mailboxes configured in the Amazon section below. Looks for emails from royalmail.com with a delivery date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: rmTracker.lastStatus)
                if let last = rmTracker.lastScan {
                    LabeledContent("Last scan", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last scan", value: "never")
                }
                if let err = rmTracker.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if !rmTracker.recentUpdates.isEmpty {
                    LabeledContent("Recent updates") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rmTracker.recentUpdates.prefix(6)) { upd in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(upd.item)
                                        .font(.caption)
                                    Text(Self.updateDetail(upd))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh now") {
                        Task {
                            await rmTracker.refreshNow()
                            store.reload()
                        }
                    }
                    .disabled(rmTracker.isRunning)
                }
            }

            Section("Amazon Mail Tracking (via Mail.app)") {
                Toggle("Enable periodic scan (every 15 min)", isOn: $amzTracker.isEnabled)

                LabeledContent("Mailboxes") {
                    TextField("Mailboxes", text: $amzTracker.watchedMailboxes, prompt: Text("Inbox, @4 Delivery"))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Comma-separated. Case-insensitive. Same list used by future mail-based trackers (e.g. FedEx).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: amzTracker.lastStatus)
                if let last = amzTracker.lastScan {
                    LabeledContent("Last scan", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last scan", value: "never")
                }
                if let err = amzTracker.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if !amzTracker.recentActions.isEmpty {
                    LabeledContent("Recent actions") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(amzTracker.recentActions.prefix(8)) { act in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(act.kind.rawValue)
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                        Text(act.item)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    Text(act.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh now") {
                        Task {
                            await amzTracker.refreshNow()
                            store.reload()
                        }
                    }
                    .disabled(amzTracker.isRunning)
                }
            }

            Section("FedEx Tracking (via texts in 03.95)") {
                Toggle("Enable periodic scan (every 15 min)", isOn: $fedexTracker.isEnabled)

                LabeledContent("Status", value: fedexTracker.lastStatus)
                if let last = fedexTracker.lastScan {
                    LabeledContent("Last scan", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last scan", value: "never")
                }
                if let err = fedexTracker.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if !fedexTracker.recentUpdates.isEmpty {
                    LabeledContent("Recent updates") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(fedexTracker.recentUpdates.prefix(6)) { upd in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(upd.item)
                                        .font(.caption)
                                    Text(Self.updateDetail(upd))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh now") {
                        Task {
                            await fedexTracker.refreshNow()
                            store.reload()
                        }
                    }
                    .disabled(fedexTracker.isRunning)
                }
            }

            Section("DHL Tracking (via API)") {
                Toggle("Enable periodic scan (hourly)", isOn: $dhlTracker.isEnabled)

                LabeledContent("Status", value: dhlTracker.lastStatus)
                if let last = dhlTracker.lastScan {
                    LabeledContent("Last scan", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last scan", value: "never")
                }
                if let err = dhlTracker.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if !dhlTracker.recentUpdates.isEmpty {
                    LabeledContent("Recent updates") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dhlTracker.recentUpdates.prefix(6)) { upd in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(upd.item)
                                        .font(.caption)
                                    Text(Self.updateDetail(upd))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh now") {
                        Task {
                            await dhlTracker.refreshNow()
                            store.reload()
                        }
                    }
                    .disabled(dhlTracker.isRunning)
                }
            }

            Section("Parcel (all carriers except Royal Mail)") {
                Toggle("Enable periodic scan (hourly)", isOn: $parcelTracker.isEnabled)

                LabeledContent("Status", value: parcelTracker.lastStatus)
                if let last = parcelTracker.lastScan {
                    LabeledContent("Last scan", value: last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Last scan", value: "never")
                }
                if let err = parcelTracker.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                Text("Reads expected dates + status from the Parcel app for any note whose tracking number (or, for Amazon, order number) is in Parcel. Key in ~/.config/parcel/credentials.json. Read-only — never creates notes, never auto-flips to delivered.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !parcelTracker.recentUpdates.isEmpty {
                    LabeledContent("Recent updates") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(parcelTracker.recentUpdates.prefix(6)) { upd in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(upd.item)
                                        .font(.caption)
                                    Text(Self.updateDetail(upd))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh now") {
                        Task {
                            await parcelTracker.refreshNow()
                            store.reload()
                        }
                    }
                    .disabled(parcelTracker.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear { draftFolder = store.deliveriesFolder }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draftFolder.isEmpty ? store.deliveriesFolder : draftFolder)
        if panel.runModal() == .OK, let url = panel.url {
            draftFolder = url.path(percentEncoded: false)
        }
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static func updateDetail(_ upd: TrackingUpdate) -> String {
        let newStr = shortDate.string(from: upd.newConfirmedDelivery)
        if let prev = upd.previousConfirmedDelivery {
            let prevStr = shortDate.string(from: prev)
            return "\(prevStr) → \(newStr) · \(upd.source)"
        }
        return "→ \(newStr) · \(upd.source)"
    }
}

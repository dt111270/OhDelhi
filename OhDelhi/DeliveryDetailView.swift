//
//  DeliveryDetailView.swift
//  OhDelhi
//
//  Right pane: full detail for one delivery. Status menu, Track / Email /
//  Delivered / Edit / Obsidian action buttons, metadata block, body.
//

import SwiftUI
import AppKit

struct DeliveryDetailView: View {
    @Environment(DeliveryStore.self) private var store

    let delivery: Delivery?

    @State private var editing = false

    var body: some View {
        if let d = delivery {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(d)
                    statusBar(d)
                    metadata(d)
                    actions(d)
                    if !d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        bodySection(d)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(d.item)
            .sheet(isPresented: $editing) {
                EditDetailsSheet(delivery: d)
                    .environment(store)
            }
        } else {
            ContentUnavailableView(
                "No delivery selected",
                systemImage: "shippingbox",
                description: Text("Pick a delivery from the list.")
            )
        }
    }

    // MARK: - Header

    private func header(_ d: Delivery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(d.vendor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(d.item)
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Status

    private func statusBar(_ d: Delivery) -> some View {
        HStack(spacing: 12) {
            Label(d.status.displayName, systemImage: d.status.systemImage)
                .foregroundStyle(d.status.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(d.status.tint.opacity(0.12), in: Capsule())

            Text(d.countdownLabel)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(d.countdownTint)

            Spacer(minLength: 0)

            Menu("Change status") {
                ForEach(DeliveryStatus.allCases.sorted(by: { $0.pipelineRank < $1.pipelineRank })) { s in
                    Button {
                        setStatus(s, on: d)
                    } label: {
                        Label(s.displayName, systemImage: s.systemImage)
                    }
                    .disabled(s == d.status)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Metadata

    private func metadata(_ d: Delivery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let expected = d.expectedDeliveryDisplay {
                metaRow("Expected", value: expected)
            }
            if let confirmed = d.confirmedDeliveryDisplay {
                metaRow("Confirmed", value: confirmed)
            }
            if let order = d.orderDateDisplay {
                metaRow("Ordered", value: order)
            }
            if let num = d.orderNumber {
                metaRow("Order #", value: num)
            }
            if let carrier = d.carrier {
                metaRow("Carrier", value: carrier)
            }
            if let track = d.trackingNumber {
                metaRow("Tracking", value: track)
            }
            if let qty = d.quantity {
                metaRow("Quantity", value: "\(qty)")
            }
            if let total = d.totalDisplay {
                metaRow("Total", value: total)
            }
        }
        .font(.subheadline)
    }

    private func metaRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func actions(_ d: Delivery) -> some View {
        HStack(spacing: 10) {
            if let url = d.trackingURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Track", systemImage: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(d.status.tint)
            }

            if let url = d.emailURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Email", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
            }

            if d.status != .delivered {
                Button {
                    markReceived(d)
                } label: {
                    Label("Delivered", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
            }

            Button {
                editing = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            if let url = ObsidianLink.url(for: d.fileURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Obsidian", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Body

    private func bodySection(_ d: Delivery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(d.body.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Writeback

    private func setStatus(_ status: DeliveryStatus, on d: Delivery) {
        do {
            try NoteEditor.setField("status", to: status.rawValue, in: d.fileURL)
            if status == .delivered {
                if d.confirmedDelivery == nil {
                    try NoteEditor.setTodayDate("confirmed_delivery", in: d.fileURL)
                }
                logDeliveredToDailyNote(d)
            }
            store.reload()
        } catch {
            NSSound.beep()
        }
    }

    private func markReceived(_ d: Delivery) {
        do {
            try NoteEditor.setField("status", to: DeliveryStatus.delivered.rawValue, in: d.fileURL)
            try NoteEditor.setTodayDate("confirmed_delivery", in: d.fileURL)
            logDeliveredToDailyNote(d)
            store.reload()
        } catch {
            NSSound.beep()
        }
    }

    /// `- *HH:MM* - DELIVERED: [[stem]]` into today's daily note. Idempotent
    /// per stem — a second flip on the same day is a no-op. Failures are
    /// swallowed; we don't want to roll back the status change just because
    /// the daily note isn't writable.
    private func logDeliveredToDailyNote(_ d: Delivery) {
        let stem  = d.fileURL.deletingPathExtension().lastPathComponent
        let time  = NoteEditor.currentTimeHHMM()
        let line  = "- *\(time)* - DELIVERED: [[\(stem)]]"
        let dedup = "DELIVERED: [[\(stem)]]"
        _ = try? NoteEditor.appendToDailyNote(line, dedupeOn: dedup)
    }
}

// MARK: - Edit details sheet

/// Tiny modal that exposes the three fields most likely to need a manual fix:
/// carrier, tracking URL, and the confirmed delivery date. Saving writes all
/// three (clearing any that have been emptied out).
private struct EditDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DeliveryStore.self) private var store

    let delivery: Delivery

    @State private var carrier: String = ""
    @State private var trackingURL: String = ""
    @State private var hasConfirmedDate: Bool = false
    @State private var confirmedDate: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit \(delivery.vendor) — \(delivery.item)")
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("Carrier", text: $carrier, prompt: Text("e.g. Royal Mail"))
                    TextField("Tracking URL", text: $trackingURL, prompt: Text("https://…"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Section("Confirmed delivery") {
                    Toggle("Has confirmed date", isOn: $hasConfirmedDate)
                    if hasConfirmedDate {
                        DatePicker(
                            "Date",
                            selection: $confirmedDate,
                            displayedComponents: .date
                        )
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360)
        .onAppear { loadCurrentValues() }
    }

    private func loadCurrentValues() {
        carrier = delivery.carrier ?? ""
        trackingURL = delivery.trackingURLString ?? ""
        if let cd = delivery.confirmedDelivery {
            hasConfirmedDate = true
            confirmedDate = cd
        } else {
            hasConfirmedDate = false
            confirmedDate = delivery.expectedDelivery ?? Date()
        }
    }

    private func save() {
        let trimmedCarrier = carrier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL     = trackingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try NoteEditor.setField(
                "carrier",
                to: trimmedCarrier.isEmpty ? nil : trimmedCarrier,
                in: delivery.fileURL
            )
            try NoteEditor.setField(
                "tracking_url",
                to: trimmedURL.isEmpty ? nil : trimmedURL,
                in: delivery.fileURL
            )
            if hasConfirmedDate {
                try NoteEditor.setField(
                    "confirmed_delivery",
                    to: Self.isoFormatter.string(from: confirmedDate),
                    in: delivery.fileURL
                )
            } else {
                try NoteEditor.setField("confirmed_delivery", to: nil, in: delivery.fileURL)
            }
            store.reload()
        } catch {
            NSSound.beep()
        }
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

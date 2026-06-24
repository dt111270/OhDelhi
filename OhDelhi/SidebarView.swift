//
//  SidebarView.swift
//  OhDelhi
//
//  Two-section sidebar: Smart Filters on top (Today/Tomorrow/This Week/
//  Overdue/All Expected/Recently Delivered), Status groups below. Each row
//  carries a count badge; a small "Updated HH:MM" footer mirrors Oatly and
//  Ommediate's sidebar footer.
//

import SwiftUI

struct SidebarView: View {
    @Environment(DeliveryStore.self) private var store

    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Smart Filters") {
                    ForEach(SmartFilter.allCases) { filter in
                        sidebarRow(
                            title: filter.displayName,
                            systemImage: filter.systemImage,
                            tint: filter.tint,
                            count: store.count(for: filter)
                        )
                        .tag(SidebarSelection.smart(filter))
                    }
                }

                Section("Status") {
                    ForEach(DeliveryStatus.allCases.sorted(by: { $0.pipelineRank < $1.pipelineRank })) { status in
                        sidebarRow(
                            title: status.displayName,
                            systemImage: status.systemImage,
                            tint: status.tint,
                            count: store.count(forStatus: status)
                        )
                        .tag(SidebarSelection.status(status))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                if let last = store.lastLoad {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        systemImage: String,
        tint: Color,
        count: Int
    ) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

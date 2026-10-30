// SPDX-License-Identifier: GPL-3.0-only
//
//  GalleryView.swift
//  Apricot SSTV Watch Watch App
//
//  Pictures saved on the watch, newest first, each marked when the
//  iPhone has it. Swipe to delete one; "Delete Synced" clears those
//  already on the iPhone.
//

import SwiftUI
import Combine

struct GalleryView: View {
    @StateObject private var list = ReceptionList()
    @State private var confirmDeleteSynced = false

    var body: some View {
        List {
            if list.items.isEmpty {
                Text("No pictures yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(list.items) { meta in
                NavigationLink {
                    ReceptionDetailView(meta: meta, synced: list.syncedIDs.contains(meta.id))
                } label: {
                    ReceptionRow(meta: meta, synced: list.syncedIDs.contains(meta.id))
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    WatchSync.shared.delete(id: list.items[i].id)
                }
            }

            if !list.syncedIDs.isEmpty {
                Button(role: .destructive) {
                    confirmDeleteSynced = true
                } label: {
                    Text("Delete Synced (\(list.syncedIDs.count))")
                }
            }

            if !list.items.isEmpty && !WatchSync.shared.canSend {
                Text("Pictures go to the iPhone once its Apricot SSTV app is installed and nearby.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Pictures")
        .confirmationDialog(
            "Delete \(list.syncedIDs.count) pictures already on the iPhone?",
            isPresented: $confirmDeleteSynced,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                WatchSync.shared.deleteSynced()
            }
        }
    }
}

// MARK: - Row

private struct ReceptionRow: View {
    let meta: ReceptionMeta
    let synced: Bool

    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(meta: meta)
                .frame(width: 44, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(meta.mode)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(meta.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: synced ? "iphone" : "clock")
                .font(.system(size: 12))
                .foregroundStyle(synced ? .green : .secondary)
                .accessibilityLabel(synced ? Text("On iPhone") : Text("Not synced yet"))
        }
    }
}

// MARK: - Detail

private struct ReceptionDetailView: View {
    let meta: ReceptionMeta
    let synced: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Thumbnail(meta: meta)
                    .aspectRatio(
                        CGFloat(max(1, meta.imageWidth)) / CGFloat(max(1, meta.imageHeight)),
                        contentMode: .fit
                    )

                Text(meta.mode)
                    .font(.headline)
                Text(meta.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    row("Rows", "\(meta.rows)/\(meta.height)")
                    row("Ended", meta.endDescription)
                    row("Start", meta.start == "vis" ? "VIS" : String(localized: "sync"))
                    row("Clock", meta.ppmValid ? "\(signed(meta.ppm)) ppm" : "?")
                    if meta.syncSeen > 0 {
                        row("Sync", "\(meta.syncGood * 100 / meta.syncSeen)%")
                    }
                    row("Offset", "\(signed(meta.offsetHz)) Hz")
                    row("iPhone", synced ? String(localized: "Synced") : String(localized: "Not yet"))
                }
                .padding(.top, 2)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("Delete").frame(maxWidth: .infinity)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 2)
        }
        .confirmationDialog(
            synced
                ? String(localized: "Delete this picture from the watch?")
                : String(localized: "This picture isn't on the iPhone yet. Delete it?"),
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                WatchSync.shared.delete(id: meta.id)
                dismiss()
            }
        }
    }

    private func signed(_ n: Int) -> String {
        n > 0 ? "+\(n)" : "\(n)"
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

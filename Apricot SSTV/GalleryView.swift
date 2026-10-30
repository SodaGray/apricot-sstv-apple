// SPDX-License-Identifier: GPL-3.0-only
//
//  GalleryView.swift
//  Apricot SSTV
//
//  Every saved picture: received on this iPhone, or on the watch and
//  copied here, as a two-column grid. The grid is built from rows of a
//  system list (two pictures per row, no row background), so its title,
//  margins and first-row height are the system's, the same as on
//  Receive and Send. Tap a picture for details; long press to share or
//  delete. Select (top left) picks several to share or delete from a
//  bottom bar, as in Photos; the menu at the top right filters by where
//  a picture was received.
//

import SwiftUI
import Combine

// MARK: - Gallery

private enum SourceFilter: String, CaseIterable, Identifiable {
    case all, watch, phone
    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All Pictures")
        case .watch: String(localized: "From Apple Watch")
        case .phone: String(localized: "From iPhone")
        }
    }

    func includes(_ meta: ReceptionMeta) -> Bool {
        self == .all || meta.device == rawValue
    }
}

struct GalleryView: View {
    @StateObject private var list = ReceptionList()
    @State private var path: [String] = []
    @State private var filter: SourceFilter = .all
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @Environment(\.scenePhase) private var scenePhase

    private static let columns = 2

    private var items: [ReceptionMeta] {
        list.items.filter(filter.includes)
    }

    /// The pictures, two to a row.
    private var rows: [[ReceptionMeta]] {
        stride(from: 0, to: items.count, by: Self.columns).map {
            Array(items[$0..<min($0 + Self.columns, items.count)])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if list.items.isEmpty {
                    ContentUnavailableView(
                        "No Pictures",
                        systemImage: "photo.on.rectangle",
                        description: Text("Pictures you receive here or on Apple Watch appear here.")
                    )
                } else if items.isEmpty {
                    ContentUnavailableView(
                        filter == .watch
                            ? LocalizedStringKey("No Pictures from Apple Watch")
                            : LocalizedStringKey("No Pictures from iPhone"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Choose All Pictures in the menu at the top right.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle(selecting ? selectionTitle : String(localized: "Pictures"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .toolbar(selecting ? .hidden : .visible, for: .tabBar)
            .navigationDestination(for: String.self) { id in
                if let meta = list.items.first(where: { $0.id == id }) {
                    ReceptionDetailView(meta: meta)
                } else {
                    ContentUnavailableView("Picture Deleted", systemImage: "trash")
                }
            }
            .confirmationDialog(
                selected.count == 1
                    ? String(localized: "Delete this picture?")
                    : String(localized: "Delete \(selected.count) pictures?"),
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { list.reload() }
        }
        .onChange(of: list.items) {
            // Drop selections whose pictures are gone.
            let ids = Set(list.items.map(\.id))
            selected.formIntersection(ids)
        }
    }

    private var grid: some View {
        List {
            Section {
                ForEach(rows, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { meta in
                            cell(meta)
                        }
                        if row.count < Self.columns {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var selectionTitle: String {
        selected.isEmpty
            ? String(localized: "Select Pictures")
            : String(localized: "\(selected.count) Selected")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("Done") { endSelecting() }
                    .fontWeight(.semibold)
            } else {
                Button("Select") { selecting = true }
                    .disabled(items.isEmpty)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button(selected.count == items.count ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")) {
                    if selected.count == items.count {
                        selected.removeAll()
                    } else {
                        selected = Set(items.map(\.id))
                    }
                }
            } else {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(SourceFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all
                          ? "line.3.horizontal.decrease"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }

        if selecting {
            ToolbarItem(placement: .bottomBar) {
                ShareLink(items: selectedURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(selected.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private var selectedURLs: [URL] {
        items.filter { selected.contains($0.id) }.map { ReceptionStore.imageURL(for: $0.id) }
    }

    // MARK: Cells

    private func cell(_ meta: ReceptionMeta) -> some View {
        Button {
            if selecting {
                if selected.contains(meta.id) {
                    selected.remove(meta.id)
                } else {
                    selected.insert(meta.id)
                }
            } else {
                path.append(meta.id)
            }
        } label: {
            GalleryCell(meta: meta, selection: selecting ? selected.contains(meta.id) : nil)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contextMenu {
            if !selecting {
                ShareLink(item: ReceptionStore.imageURL(for: meta.id))
                Button(role: .destructive) {
                    try? ReceptionStore.delete(id: meta.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityAddTraits(selecting && selected.contains(meta.id) ? .isSelected : [])
    }

    // MARK: Actions

    private func endSelecting() {
        selecting = false
        selected.removeAll()
    }

    private func deleteSelected() {
        for id in selected {
            try? ReceptionStore.delete(id: id)
        }
        endSelecting()
    }
}

private struct GalleryCell: View {
    let meta: ReceptionMeta
    /// nil when not selecting; otherwise whether this one is selected.
    let selection: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumbnail(meta: meta, cornerRadius: 0)
                .aspectRatio(320.0 / 256.0, contentMode: .fit)
                .clipShape(Design.thumbnailShape)
                .overlay(alignment: .bottomTrailing) {
                    if let selection {
                        Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, selection ? Color.accentColor : Color.black.opacity(0.25))
                            .shadow(radius: 1)
                            .padding(6)
                    }
                }
                .opacity(selection == false ? 0.75 : 1)

            Text(meta.mode)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 0) {
                Text(meta.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if meta.device == "watch" {
                    Text(" · from Watch")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct ReceptionDetailView: View {
    let meta: ReceptionMeta

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Thumbnail(meta: meta, cornerRadius: 0)
                    .aspectRatio(
                        CGFloat(max(1, meta.imageWidth)) / CGFloat(max(1, meta.imageHeight)),
                        contentMode: .fit
                    )
                    .listRowInsets(EdgeInsets())
            }

            Section("Reception") {
                LabeledContent("Mode", value: meta.mode)
                LabeledContent("Started") {
                    Text(meta.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Received on", value: meta.deviceDescription)
                LabeledContent("Rows", value: String(localized: "\(meta.rows) of \(meta.height)"))
                LabeledContent("Ended", value: meta.endDescription)
                LabeledContent("Started by", value: meta.startDescription)
            }

            Section("Signal") {
                LabeledContent("Sender's clock", value: meta.ppmValid ? "\(signed(meta.ppm)) ppm" : String(localized: "Not measured"))
                if meta.syncSeen > 0 {
                    LabeledContent("Syncs found", value: "\(meta.syncGood * 100 / meta.syncSeen)%")
                }
                LabeledContent("Tuning offset", value: "\(signed(meta.offsetHz)) Hz")
                if meta.relocks > 0 {
                    LabeledContent("Resumed", value: "\(meta.relocks)×")
                }
                LabeledContent("Image", value: "\(meta.imageWidth) × \(meta.imageHeight)")
            }
        }
        .navigationTitle(meta.mode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: ReceptionStore.imageURL(for: meta.id))
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this picture?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                try? ReceptionStore.delete(id: meta.id)
                dismiss()
            }
        }
    }

    private func signed(_ n: Int) -> String {
        n > 0 ? "+\(n)" : "\(n)"
    }
}

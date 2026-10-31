// SPDX-License-Identifier: GPL-3.0-only
//
//  EventsView.swift
//  Apricot SSTV
//
//  Events (Events.swift) in the gallery: the list, one event with its
//  pictures, and the form to make or change one.
//
//  An event's pictures are grouped by when they came in: a gap of more
//  than 20 minutes starts a new group (a new pass of a satellite, the
//  next evening of a net). Nothing is stored for that; it's worked out
//  from the times each time.
//
//  Making an event current is always by hand (the form's switch, or the
//  button on the event), shown at the top of the gallery and on Receive,
//  and it stops by itself at the end of the event's last day.
//

import SwiftUI
import Combine

// MARK: - Banner

/// The top of the gallery while an event is current.
struct CurrentEventBanner: View {
    let event: SSTVEvent
    let cover: ReceptionMeta?

    var body: some View {
        NavigationLink(value: GalleryRoute.event(event.id)) {
            HStack(spacing: 12) {
                CoverView(cover: cover)
                    .frame(width: 56, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(currentLine(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// An event's picture, or a calendar where it has none yet.
struct CoverView: View {
    let cover: ReceptionMeta?

    var body: some View {
        if let cover {
            Thumbnail(meta: cover, cornerRadius: 6)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// "New pictures go here until Nov 7, 00:00"
private func currentLine(_ event: SSTVEvent) -> String {
    guard let until = event.currentUntil else { return "" }
    let time = until.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    return String(localized: "New pictures go here until \(time)")
}

private func dayRange(_ event: SSTVEvent) -> String {
    let cal = Calendar.current
    let style: Date.FormatStyle = .dateTime.year().month(.abbreviated).day()
    if cal.isDate(event.firstDay, inSameDayAs: event.lastDay) || event.lastDay < event.firstDay {
        return event.firstDay.formatted(style)
    }
    return "\(event.firstDay.formatted(style)) – \(event.lastDay.formatted(style))"
}

// MARK: - List

struct EventsListView: View {
    @ObservedObject var list: ReceptionList
    @State private var creating = false
    @State private var deleting: SSTVEvent?

    var body: some View {
        Group {
            if list.events.isEmpty {
                ContentUnavailableView {
                    Label("No Events", systemImage: "calendar")
                } description: {
                    Text("While an event is current, new pictures go into it by themselves.")
                } actions: {
                    Button("New Event") { creating = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                List {
                    ForEach(list.events) { event in
                        NavigationLink(value: GalleryRoute.event(event.id)) {
                            row(event)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                deleting = event
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Label("New Event", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) {
            EventEditor(event: nil) { _ in }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { event in
            Button("Delete Event", role: .destructive) {
                EventStore.delete(id: event.id)
            }
        } message: { _ in
            Text("Its pictures stay, in no event.")
        }
    }

    private var deleteTitle: String {
        let name = deleting?.displayName ?? ""
        return String(localized: "Delete “\(name)”?")
    }

    private func row(_ event: SSTVEvent) -> some View {
        let count = list.pictures(in: event).count
        return HStack(spacing: 12) {
            CoverView(cover: list.cover(of: event))
                .frame(width: 64, height: 48)
            rowText(event, count: count)
        }
    }

    private func rowText(_ event: SSTVEvent, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if event.isCurrent() {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            HStack(spacing: 0) {
                Text(dayRange(event))
                if !event.frequency.isEmpty {
                    Text(verbatim: " · \(event.frequency) MHz")
                }
                Text(verbatim: " · ")
                Text("\(count) pictures")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - One event

struct EventDetailView: View {
    let eventID: UUID
    @ObservedObject var list: ReceptionList

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false

    private var event: SSTVEvent? {
        list.events.first { $0.id == eventID }
    }

    private var pictures: [ReceptionMeta] {
        list.items.filter { list.notes[$0.id]?.event == eventID && !list.fragmentIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if let event {
                content(event)
            } else {
                ContentUnavailableView("Event Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(event?.displayName ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if event != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editing = true
                        } label: {
                            Label("Edit Event", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Event", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let event {
                EventEditor(event: event) { _ in }
            }
        }
        .confirmationDialog(
            "Delete this event?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Event", role: .destructive) {
                EventStore.delete(id: eventID)
                dismiss()
            }
        } message: {
            Text("Its pictures stay, in no event.")
        }
    }

    private func content(_ event: SSTVEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                info(event)

                if pictures.isEmpty {
                    Text("No pictures yet. Add some with Select in Pictures.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
                        spacing: 16,
                        pinnedViews: []
                    ) {
                        ForEach(Self.sessions(pictures), id: \.first?.id) { session in
                            Section {
                                ForEach(session) { meta in
                                    cell(meta)
                                }
                            } header: {
                                sessionHeader(session)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Info

    private func info(_ event: SSTVEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cover = list.cover(of: event) {
                // Touch and hold a picture below to choose another.
                Thumbnail(meta: cover, cornerRadius: 10)
                    .aspectRatio(320.0 / 256.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            Label(dayRange(event), systemImage: "calendar")
            if !event.frequency.isEmpty {
                Label {
                    Text(verbatim: "\(event.frequency) MHz")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
            if !event.note.isEmpty {
                Text(event.note)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if event.isCurrent() {
                Text(currentLine(event))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    try? EventStore.endCurrent(id: event.id)
                } label: {
                    Text("Stop Adding New Pictures").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            } else if event.hasEnded {
                Text("Ended. Change its last day to make it current again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("While current, new pictures from here and Apple Watch go into it, until the end of its last day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    try? EventStore.makeCurrent(id: event.id)
                } label: {
                    Text("Make Current").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Pictures

    /// Oldest first, split where more than 20 minutes pass between one
    /// picture's end and the next one's start.
    static func sessions(_ pictures: [ReceptionMeta]) -> [[ReceptionMeta]] {
        let sorted = pictures.sorted { $0.startedAt < $1.startedAt }
        var groups: [[ReceptionMeta]] = []
        for meta in sorted {
            if let last = groups.last?.last,
               meta.startedAt.timeIntervalSince(max(last.endedAt, last.startedAt)) <= 20 * 60 {
                groups[groups.count - 1].append(meta)
            } else {
                groups.append([meta])
            }
        }
        return groups
    }

    private func sessionHeader(_ session: [ReceptionMeta]) -> some View {
        let first = session.first?.startedAt ?? .now
        let last = session.last.map { max($0.endedAt, $0.startedAt) } ?? first
        let day = first.formatted(.dateTime.month(.abbreviated).day())
        let from = first.formatted(date: .omitted, time: .shortened)
        let to = last.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 0) {
            Text(verbatim: "\(day) \(from)–\(to) · ")
            Text("\(session.count) pictures")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func cell(_ meta: ReceptionMeta) -> some View {
        NavigationLink(value: GalleryRoute.picture(meta.id)) {
            GalleryCell(meta: meta, selection: nil, title: list.notes[meta.id]?.title ?? "")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            if let event, list.cover(of: event)?.id != meta.id {
                Button {
                    EventStore.setCover(meta.id, for: eventID)
                } label: {
                    Label("Set as Cover", systemImage: "photo")
                }
            }
            ShareLink(item: ReceptionStore.displayImageURL(for: meta.id))
            Button {
                EventStore.setEvent(nil, for: [meta.id])
            } label: {
                Label("Remove from Event", systemImage: "calendar.badge.minus")
            }
        }
    }
}

// MARK: - Form

/// Makes a new event (nil) or changes one. `onSave` gets the saved event.
struct EventEditor: View {
    let event: SSTVEvent?
    let onSave: (SSTVEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var firstDay = Date.now
    @State private var lastDay = Date.now
    @State private var frequency = ""
    @State private var note = ""
    /// New events only: current from now on.
    @State private var makeCurrent = true
    @State private var loaded = false

    private var lastDayEnded: Bool {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(firstDay, lastDay))) ?? lastDay
        return end <= .now
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("ISS SSTV, a net, a test…"))
                }
                Section {
                    DatePicker("First Day", selection: $firstDay, displayedComponents: .date)
                    DatePicker("Last Day", selection: $lastDay, in: firstDay..., displayedComponents: .date)
                    LabeledContent("Frequency") {
                        HStack(spacing: 4) {
                            TextField("Frequency", text: $frequency, prompt: Text(verbatim: "145.800"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(verbatim: "MHz")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Pictures that join take this frequency, unless they have one.")
                }
                Section {
                    TextField("Note", text: $note, prompt: Text("Note"), axis: .vertical)
                        .lineLimit(3...10)
                }
                if event == nil {
                    Section {
                        Toggle("Current Event", isOn: $makeCurrent)
                            .disabled(lastDayEnded)
                    } footer: {
                        Text("While current, new pictures from here and Apple Watch go into it, until the end of its last day.")
                    }
                }
            }
            .navigationTitle(event == nil ? LocalizedStringKey("New Event") : LocalizedStringKey("Edit Event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: firstDay) {
                if lastDay < firstDay { lastDay = firstDay }
            }
            .onAppear {
                guard !loaded, let event else { loaded = true; return }
                name = event.name
                firstDay = event.firstDay
                lastDay = event.lastDay
                frequency = event.frequency
                note = event.note
                loaded = true
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFrequency = frequency.trimmingCharacters(in: .whitespaces)
        var e = event ?? SSTVEvent(name: trimmedName, firstDay: firstDay, lastDay: lastDay)
        e.name = trimmedName
        e.firstDay = firstDay
        e.lastDay = max(firstDay, lastDay)
        e.frequency = trimmedFrequency
        e.note = note
        do {
            if event == nil {
                try EventStore.save(e)
                if makeCurrent && !lastDayEnded { try EventStore.makeCurrent(id: e.id) }
            } else {
                try EventStore.update(e)
            }
            onSave(EventStore.event(id: e.id) ?? e)
        } catch {
            print("[Events] save failed: \(error.localizedDescription)")
        }
        dismiss()
    }
}

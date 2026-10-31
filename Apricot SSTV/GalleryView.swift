// SPDX-License-Identifier: GPL-3.0-only
//
//  GalleryView.swift
//  Apricot SSTV
//
//  Every saved picture: received on this iPhone, or on the watch and
//  copied here, as a two-column grid on the same grouped background and
//  with the same side margins as Receive and Send. (Not rows of a List:
//  a List row lifts as a whole for a long press, both pictures at once.)
//  Tap a picture for details; long press to share or delete. Select (top left) picks several to share or delete from a
//  bottom bar, as in Photos; the menu at the top right filters by where
//  a picture was received. A picture's details show its raw audio, if it
//  was saved, to share or delete, and Edit opens the darkroom
//  (Darkroom.swift) to develop it again from that audio. Its notes
//  (frequency, source, a note, its event) are written right there.
//  Events (calendar button, EventsView.swift) gather pictures; while one
//  is current, a banner at the top of the grid leads to it.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Gallery

/// Where the gallery's navigation can go.
enum GalleryRoute: Hashable {
    case picture(String)
    case events
    case event(UUID)
}

private enum SourceFilter: String, CaseIterable, Identifiable {
    case all, watch, phone, file, fragments
    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All Pictures")
        case .watch: String(localized: "From Apple Watch")
        case .phone: String(localized: "From iPhone")
        case .file: String(localized: "From Audio Files")
        case .fragments: String(localized: "Fragments")
        }
    }

    /// Fragments only show under Fragments.
    func includes(_ meta: ReceptionMeta, fragment: Bool) -> Bool {
        switch self {
        case .fragments: fragment
        case .all: !fragment
        case .watch, .phone, .file: !fragment && meta.device == rawValue
        }
    }
}

struct GalleryView: View {
    @StateObject private var list = ReceptionList()
    @State private var path: [GalleryRoute] = []
    @State private var filter: SourceFilter = .all
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var newEventForSelection = false
    @Environment(\.scenePhase) private var scenePhase

    /// A picture is showing: the tab bar makes way for its Share / Delete.
    private var pictureOnTop: Bool {
        if case .picture? = path.last { true } else { false }
    }

    private static let columns = 2

    private var items: [ReceptionMeta] {
        list.items.filter { filter.includes($0, fragment: list.fragmentIDs.contains($0.id)) }
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
                        emptyTitle,
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
            // The tab bar goes the moment a picture is opened or Select is
            // tapped. Their Share / Delete bar isn't a toolbar (a toolbar
            // only shows once the tab bar has finished going, leaving a gap):
            // it's part of the picture's page and slides in with it.
            .toolbar(selecting || pictureOnTop ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting {
                    ActionBar {
                        ShareLink(items: selectedURLs) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(selected.isEmpty)
                    } center: {
                        eventMenu
                    } trailing: {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selected.isEmpty)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: selecting)
            .navigationDestination(for: GalleryRoute.self) { route in
                switch route {
                case .picture(let id):
                    if let meta = list.items.first(where: { $0.id == id }) {
                        ReceptionDetailView(meta: meta, list: list)
                    } else {
                        ContentUnavailableView("Picture Deleted", systemImage: "trash")
                    }
                case .events:
                    EventsListView(list: list)
                case .event(let id):
                    EventDetailView(eventID: id, list: list)
                }
            }
            .sheet(isPresented: $newEventForSelection) {
                EventEditor(event: nil) { event in
                    EventStore.setEvent(event.id, for: selected)
                    endSelecting()
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
        ScrollView {
            if filter == .fragments {
                Text("Too few rows to count as a picture: mostly false starts, sometimes a picture caught at its very end. Each is kept with its raw audio (if saved), which may hold the whole picture: open one and Edit to develop it in the darkroom.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else if let event = list.currentEvent, !selecting {
                CurrentEventBanner(event: event)
                    .padding(.top, 8)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: Self.columns),
                spacing: 16
            ) {
                ForEach(items) { meta in
                    cell(meta)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
    }

    private var emptyTitle: LocalizedStringKey {
        switch filter {
        case .watch: "No Pictures from Apple Watch"
        case .phone: "No Pictures from iPhone"
        case .file: "No Pictures from Audio Files"
        case .fragments: "No Fragments"
        case .all: "No Pictures"
        }
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
                Button {
                    path.append(.events)
                } label: {
                    Label("Events", systemImage: "calendar")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if !selecting {
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

    }

    private var selectedURLs: [URL] {
        items.filter { selected.contains($0.id) }.map { ReceptionStore.displayImageURL(for: $0.id) }
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
                path.append(.picture(meta.id))
            }
        } label: {
            GalleryCell(meta: meta, selection: selecting ? selected.contains(meta.id) : nil)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        // Only this picture lifts for the menu, with its own corners.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            if !selecting {
                ShareLink(item: ReceptionStore.displayImageURL(for: meta.id))
                Button(role: .destructive) {
                    try? ReceptionStore.delete(id: meta.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityAddTraits(selecting && selected.contains(meta.id) ? .isSelected : [])
    }

    /// Multi-select: put the selected pictures in an event, or in none.
    private var eventMenu: some View {
        Menu {
            Section("Add to Event") {
                ForEach(list.events) { event in
                    Button(event.displayName) {
                        EventStore.setEvent(event.id, for: selected)
                        endSelecting()
                    }
                }
                Button {
                    newEventForSelection = true
                } label: {
                    Label("New Event…", systemImage: "plus")
                }
            }
            if selected.contains(where: { list.notes[$0]?.event != nil }) {
                Button(role: .destructive) {
                    EventStore.setEvent(nil, for: selected)
                    endSelecting()
                } label: {
                    Label("Remove from Event", systemImage: "calendar.badge.minus")
                }
            }
        } label: {
            Label("Event", systemImage: "calendar.badge.plus")
        }
        .disabled(selected.isEmpty)
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

struct GalleryCell: View {
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
                if meta.isFragment {
                    Text(verbatim: " · ")
                    Text("\(meta.rows) rows")
                } else if meta.device == "watch" {
                    Text(" · from Watch")
                } else if meta.device == "file" {
                    Text(" · from File")
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

/// Share at the left, Delete (red) at the right, and between them, when
/// selecting, the event menu: floating over the bottom of the page like a
/// toolbar's buttons.
private struct ActionBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            leading
                .tint(.primary)
            Spacer()
            center
                .tint(.primary)
            Spacer()
            trailing
                .tint(.red)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

extension ActionBar where Center == EmptyView {
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}

private struct ReceptionDetailView: View {
    let meta: ReceptionMeta
    @ObservedObject var list: ReceptionList

    @Environment(\.dismiss) private var dismiss
    /// The notes as being edited; written as they change, the lists told
    /// once on leaving.
    @State private var notes = PictureNotes()
    @State private var notesLoaded = false
    @State private var notesChanged = false
    @FocusState private var typing: Bool

    // Read at once, so the darkroom row is right from the first frame.
    init(meta: ReceptionMeta, list: ReceptionList) {
        self.meta = meta
        self.list = list
        _audio = State(initialValue: AudioSummary(id: meta.id))
        _edited = State(initialValue: ReceptionStore.hasEdit(id: meta.id))
    }
    @State private var confirmDelete = false
    @State private var confirmDeleteAudio = false
    @State private var audio: AudioSummary?
    @State private var edited = false
    @State private var showDarkroom = false

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

            darkroomSection

            notesSection

            Section("Reception") {
                LabeledContent("Mode", value: meta.mode)
                LabeledContent("Started") {
                    Text(meta.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Received on", value: meta.deviceDescription)
                LabeledContent("Rows", value: String(localized: "\(meta.rows) of \(meta.height)"))
                LabeledContent("Ended", value: meta.endDescription)
                LabeledContent("Started by", value: meta.startDescription)
                if edited {
                    LabeledContent("Darkroom", value: String(localized: "Developed again"))
                }
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

            if let audio {
                audioSection(audio)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(meta.mode)
        .navigationBarTitleDisplayMode(.inline)
        // As in Photos: the tab bar makes way (GalleryView hides it) for
        // the picture's own bar, Share at the left, Delete at the right.
        // Not while typing: the keyboard has the bottom then.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typing {
                bottomBar
            }
        }
        .onAppear {
            if !notesLoaded {
                notes = EventStore.notes(for: meta.id) ?? PictureNotes()
                notesLoaded = true
            }
        }
        .onChange(of: notes) { old, new in
            guard notesLoaded else { return }
            var n = new
            // Joining an event fills in its frequency, if none was written.
            if let id = n.event, id != old.event, n.frequency.isEmpty,
               let event = list.events.first(where: { $0.id == id }) {
                n.frequency = event.frequency
            }
            if n != new { notes = n; return }
            EventStore.saveNotes(n, for: meta.id, post: false)
            notesChanged = true
        }
        .onDisappear {
            if notesChanged { ReceptionStore.postChanged() }
            notesChanged = false
        }
        .toolbar {
            if typing {
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { typing = false }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .toolbar {
            // The darkroom needs the raw audio to develop from.
            if audio != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showDarkroom = true }
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
        .confirmationDialog(
            "Delete this picture's raw audio?",
            isPresented: $confirmDeleteAudio,
            titleVisibility: .visible
        ) {
            Button("Delete Raw Audio", role: .destructive) {
                try? ReceptionStore.deleteAudio(id: meta.id)
                audio = AudioSummary(id: meta.id)
            }
        } message: {
            Text("The picture stays.")
        }
        .fullScreenCover(isPresented: $showDarkroom) {
            DarkroomView(meta: meta)
        }
        .onAppear {
            audio = AudioSummary(id: meta.id)
            edited = ReceptionStore.hasEdit(id: meta.id)
        }
        // Audio from the watch arrives after its picture; edits are saved
        // from the darkroom.
        .onReceive(NotificationCenter.default.publisher(for: .receptionsChanged)) { _ in
            audio = AudioSummary(id: meta.id)
            edited = ReceptionStore.hasEdit(id: meta.id)
        }
    }

    private var bottomBar: some View {
        ActionBar {
            ShareLink(item: ReceptionStore.displayImageURL(for: meta.id)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } trailing: {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Darkroom

    /// Says plainly what the darkroom is, and whether this picture can go
    /// there: it develops again from the raw audio, it doesn't edit pixels.
    @ViewBuilder
    private var darkroomSection: some View {
        if audio != nil {
            Section {
                Button {
                    showDarkroom = true
                } label: {
                    Label(
                        edited ? LocalizedStringKey("Develop Again in the Darkroom") : LocalizedStringKey("Develop in the Darkroom"),
                        systemImage: "wand.and.stars"
                    )
                }
            } footer: {
                Text("Decodes this picture again from its raw audio, with the timing you set: not an edit of the image, so nothing is stretched or made up.")
            }
        } else {
            Section {
                Label("No Raw Audio", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
            } footer: {
                if meta.device == "watch" {
                    Text("This picture has no raw audio here, so it can't be developed again. If the watch kept it, it comes after the picture.")
                } else {
                    Text("This picture was kept without its sound, so it can't be developed again. With Save Raw Audio on, new pictures keep theirs.")
                }
            }
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section {
            Picker("Event", selection: $notes.event) {
                Text("None").tag(UUID?.none)
                ForEach(list.events) { event in
                    Text(event.displayName).tag(Optional(event.id))
                }
                // In an event that's since been deleted.
                if let id = notes.event, !list.events.contains(where: { $0.id == id }) {
                    Text("Deleted Event").tag(Optional(id))
                }
            }
            LabeledContent("Frequency") {
                HStack(spacing: 4) {
                    TextField("Frequency", text: $notes.frequency, prompt: Text(verbatim: "145.800"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($typing)
                    Text(verbatim: "MHz")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Source") {
                TextField("Source", text: $notes.source, prompt: Text("Satellite or callsign"))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .focused($typing)
            }
            TextField("Note", text: $notes.note, prompt: Text("Note"), axis: .vertical)
                .lineLimit(2...10)
                .focused($typing)
        } header: {
            Text("Notes")
        }
    }

    private func audioSection(_ audio: AudioSummary) -> some View {
        Section {
            LabeledContent("Length") {
                Text(Duration.seconds(audio.seconds), format: .time(pattern: .minuteSecond))
            }
            LabeledContent("Size") {
                Text(audio.bytes, format: .byteCount(style: .file))
            }
            LabeledContent("Sample rate", value: "\(audio.sampleRate) Hz")
            if audio.missingSeconds > 0 {
                LabeledContent("Missing") {
                    Text(Duration.seconds(audio.missingSeconds), format: .time(pattern: .minuteSecond))
                }
            }
            ShareLink(
                item: ReceptionAudio(id: meta.id),
                preview: SharePreview(
                    String(localized: "\(meta.mode) Audio"),
                    image: Image(systemName: "waveform")
                )
            ) {
                Label("Share Audio", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                confirmDeleteAudio = true
            } label: {
                Label("Delete Raw Audio", systemImage: "trash")
                    .foregroundStyle(.red)      // the icon too, not only the text
            }
        } header: {
            Text("Raw Audio")
        } footer: {
            Text("The sound this picture was decoded from, as a WAV file. Share it to decode it again in another app.")
        }
    }

    private func signed(_ n: Int) -> String {
        n > 0 ? "+\(n)" : "\(n)"
    }
}

// MARK: - Raw audio

/// What the detail shows about a picture's audio.wav.
private struct AudioSummary: Equatable {
    let seconds: Double
    let bytes: Int64
    let sampleRate: Int
    /// Audio the app lost, written as silence.
    let missingSeconds: Double

    /// nil if the picture has no audio.
    init?(id: String) {
        guard ReceptionStore.hasAudio(id: id),
              let info = ReceptionStore.audioInfo(id: id),
              info.sampleRate > 0
        else { return nil }
        let rate = Double(info.sampleRate)
        bytes = ReceptionStore.audioByteCount(id: id)
        sampleRate = info.sampleRate
        seconds = Double(max(0, bytes - 44) / 2) / rate
        missingSeconds = Double(info.gaps.reduce(0) { $0 + ($1.count > 1 ? $1[1] : 0) }) / rate
    }
}

/// A picture's audio, shared as "<id>.wav" rather than "audio.wav".
/// Nonisolated, so sharing never waits on the main actor.
nonisolated struct ReceptionAudio: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .wav) { item in
            SentTransferredFile(try item.namedFile())
        }
    }

    /// A hard link to audio.wav under its picture's name (a copy if the
    /// link can't be made). No new data is written either way for a link.
    private func namedFile() throws -> URL {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "SharedAudio", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "\(id).wav")
        try? fm.removeItem(at: dest)
        let source = ReceptionStore.audioURL(for: id)
        do {
            try fm.linkItem(at: source, to: dest)
        } catch {
            try fm.copyItem(at: source, to: dest)
        }
        return dest
    }
}

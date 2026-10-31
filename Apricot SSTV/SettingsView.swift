// SPDX-License-Identifier: GPL-3.0-only
//
//  SettingsView.swift
//  Apricot SSTV
//
//  The Settings tab: the few things worth remembering (receive mode,
//  starting without VIS, the receive timeout, saving raw audio, the
//  callsign drawn on sent pictures), how much is saved, whether the
//  watch is set up, and the introduction, Help and About.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var rx: Receiver
    @StateObject private var list = ReceptionList()

    @AppStorage("tx.callsign") private var callsign = ""
    @State private var callsignDraft = ""
    @FocusState private var editingCallsign: Bool

    @State private var usage = LibraryTransfer.Usage()
    @State private var confirmDeleteAudio = false
    @State private var exporting = false
    @State private var importing = false
    @State private var transferMessage: String?
    @State private var watchStatus: PhoneSync.WatchStatus = .notPaired
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteFragments = false
    @State private var showIntroduction = false

    var body: some View {
        NavigationStack {
            Form {
                receivingSection
                sendingSection
                picturesSection
                watchSection
                otherSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            callsignDraft = callsign
            refresh()
        }
        // Any save, arrival or delete (audio too) changes the space used.
        .onReceive(NotificationCenter.default.publisher(for: .receptionsChanged)) { _ in
            refresh()
        }
        .onChange(of: editingCallsign) {
            if !editingCallsign, callsignDraft != callsign { callsign = callsignDraft }
        }
        .onChange(of: callsign) { callsignDraft = callsign }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .watchStateChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            watchStatus = PhoneSync.shared.watchStatus
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var receivingSection: some View {
        Section {
            Picker("Mode", selection: $rx.chosenMode) {
                Text("Automatic").tag(Int?.none)
                ForEach(SSTVMode.all) { m in
                    Text(verbatim: m.name).tag(Optional(m.vis))
                }
            }
            Toggle("Start Without VIS", isOn: $rx.autosync)
        } header: {
            Text("Receiving")
        } footer: {
            Text("Start Without VIS locks on to the line syncs when the header was missed.")
        }

        Section {
            Picker("Receive Timeout", selection: $rx.timeoutMinutes) {
                ForEach(Receiver.timeoutChoices, id: \.self) { minutes in
                    Text(timeoutTitle(minutes)).tag(minutes)
                }
            }
        } footer: {
            Text("Listening stops when no picture has come in for this long.")
        }

        Section {
            Toggle("Save Raw Audio", isOn: $rx.saveAudio)
            if rx.saveAudio {
                Picker("Sample Rate", selection: $rx.fullRateAudio) {
                    Text("12 kHz").tag(false)
                    Text("Full Rate").tag(true)
                }
            }
        } footer: {
            if rx.saveAudio {
                Text("12 kHz holds everything the decoder uses: about 8 MB for a Martin M1 picture. Full Rate keeps the sound as it came in, usually 48 kHz, at four times the size. A change applies the next time you start. Apple Watch has its own setting, always at 12 kHz.")
            } else {
                Text("Needed to develop a picture again in the darkroom. Apple Watch has its own setting.")
            }
        }
    }

    private var sendingSection: some View {
        Section {
            TextField("Callsign", text: $callsignDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($editingCallsign)
                .submitLabel(.done)
                .onSubmit { editingCallsign = false }
        } header: {
            Text("Sending")
        } footer: {
            Text("Drawn at the top left of every picture you send.")
        }
    }

    private var picturesSection: some View {
        Section {
            LabeledContent("Saved Pictures") {
                Text(verbatim: "\(list.items.count - list.fragmentIDs.count)")
                    .monospacedDigit()
            }
            if !list.fragmentIDs.isEmpty {
                LabeledContent("Fragments") {
                    Text(verbatim: "\(list.fragmentIDs.count)")
                        .monospacedDigit()
                }
            }
            LabeledContent("Pictures") {
                Text(usage.pictures, format: .byteCount(style: .file)).monospacedDigit()
            }
            LabeledContent("Raw Audio") {
                Text(usage.audio, format: .byteCount(style: .file)).monospacedDigit()
            }
            if usage.favorites > 0 {
                LabeledContent("Favorites") {
                    Text(usage.favorites, format: .byteCount(style: .file)).monospacedDigit()
                }
            }

            Button {
                exporting = true
            } label: {
                Label("Export Library…", systemImage: "square.and.arrow.up")
            }
            .disabled(list.items.isEmpty && usage.favorites == 0)
            .fileExporter(
                isPresented: $exporting,
                document: LibraryExport(),
                contentType: .folder,
                defaultFilename: LibraryExport.defaultName
            ) { result in
                if case .failure(let error) = result { transferMessage = error.localizedDescription }
            }

            Button {
                importing = true
            } label: {
                Label("Import Library…", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): importLibrary(url)
                case .failure(let error): transferMessage = error.localizedDescription
                }
            }

            Button("Delete All Raw Audio", role: .destructive) {
                confirmDeleteAudio = true
            }
            .disabled(usage.audio == 0)
            .confirmationDialog(
                "Delete the raw audio of every picture on this iPhone?",
                isPresented: $confirmDeleteAudio,
                titleVisibility: .visible
            ) {
                Button("Delete All Raw Audio", role: .destructive) {
                    Task.detached(priority: .userInitiated) { LibraryTransfer.deleteAllAudio() }
                }
            } message: {
                Text("The pictures stay.")
            }

            Button("Delete All Fragments", role: .destructive) {
                confirmDeleteFragments = true
            }
            .disabled(list.fragmentIDs.isEmpty)
            .confirmationDialog(
                String(localized: "Delete all \(list.fragmentIDs.count) fragments from this iPhone?"),
                isPresented: $confirmDeleteFragments,
                titleVisibility: .visible
            ) {
                Button("Delete All Fragments", role: .destructive) {
                    for id in list.fragmentIDs { try? ReceptionStore.delete(id: id) }
                }
            } message: {
                Text("Their raw audio may still hold a picture.")
            }

            Button("Delete All Pictures", role: .destructive) {
                confirmDeleteAll = true
            }
            .disabled(list.items.isEmpty)
            .confirmationDialog(
                String(localized: "Delete all \(list.items.count) pictures from this iPhone?"),
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Pictures", role: .destructive) { deleteAll() }
            } message: {
                Text("Pictures on Apple Watch are not affected.")
            }
        } header: {
            Text("Pictures")
        } footer: {
            Text("Import Library takes back a folder made by Export Library. For a recording made elsewhere, use Decode Audio File on Receive.")
        }
        .alert(
            transferMessage ?? "",
            isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private func importLibrary(_ url: URL) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try LibraryTransfer.importFolder(url) }
            }.value
            switch outcome {
            case .success(let r):
                if r.pictures == 0 && r.favorites == 0 && r.events == 0 && r.skipped == 0 {
                    transferMessage = String(localized: "No Apricot SSTV pictures were found in that folder.")
                } else {
                    transferMessage = String(localized: "Imported \(r.pictures) pictures, \(r.events) events and \(r.favorites) favorites. \(r.skipped) were already here.")
                }
            case .failure(let error):
                transferMessage = error.localizedDescription
            }
            refresh()
        }
    }

    private var watchSection: some View {
        Section {
            LabeledContent("Status", value: watchStatusText)
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Pictures from Apple Watch come to this iPhone by themselves.")
        }
    }

    private var otherSection: some View {
        Section {
            Button {
                showIntroduction = true
            } label: {
                Label {
                    Text("Introduction").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
            .sheet(isPresented: $showIntroduction) {
                OnboardingView(purpose: .review)
                    .environmentObject(rx)
            }
            NavigationLink {
                HelpView()
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            NavigationLink {
                AboutView()
            } label: {
                Label("About Apricot SSTV", systemImage: "info.circle")
            }
            WebLink("Privacy Policy", systemImage: "hand.raised", destination: AppInfo.privacyPolicy)
            WebLink("Source Code", systemImage: "chevron.left.forwardslash.chevron.right", destination: AppInfo.source)
        } footer: {
            Text(verbatim: "\(AppInfo.name) \(AppInfo.version)")
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    // MARK: Helpers

    private func timeoutTitle(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "Never") : String(localized: "\(minutes) min")
    }

    private var watchStatusText: String {
        switch watchStatus {
        case .unsupported: String(localized: "Not available")
        case .notPaired: String(localized: "No Apple Watch paired")
        case .appNotInstalled: String(localized: "Watch app not installed")
        case .ready: String(localized: "Ready")
        }
    }

    private func refresh() {
        watchStatus = PhoneSync.shared.watchStatus
        Task {
            usage = await Task.detached(priority: .utility) { LibraryTransfer.usage() }.value
        }
    }

    private func deleteAll() {
        for meta in list.items {
            try? ReceptionStore.delete(id: meta.id)
        }
    }
}

/// A row that opens a web page in Safari: a label, and an arrow on the
/// right instead of a chevron, so it doesn't look like it stays in the app.
struct WebLink: View {
    let title: LocalizedStringKey
    let systemImage: String
    let destination: URL

    init(_ title: LocalizedStringKey, systemImage: String, destination: URL) {
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                // In the link's own colour: a faint arrow looked disabled.
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

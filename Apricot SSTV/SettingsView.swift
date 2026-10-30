// SPDX-License-Identifier: GPL-3.0-only
//
//  SettingsView.swift
//  Apricot SSTV
//
//  The Settings tab: the few things worth remembering (receive mode,
//  starting without VIS, the callsign drawn on sent pictures), how much
//  is saved, whether the watch is set up, and Help and About.
//

import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject private var rx: Receiver
    @StateObject private var list = ReceptionList()

    @AppStorage("tx.callsign") private var callsign = ""
    @State private var callsignDraft = ""
    @FocusState private var editingCallsign: Bool

    @State private var storageBytes: Int64 = 0
    @State private var watchStatus: PhoneSync.WatchStatus = .notPaired
    @State private var confirmDeleteAll = false

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
        .onChange(of: list.items) { refresh() }
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
            Text("Automatic finds the mode from each picture's VIS header. Choose a mode to receive only that one. Start Without VIS locks on to the line syncs when the header was missed.")
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
            Text("Drawn at the top left of every picture you send, to identify your station.")
        }
    }

    private var picturesSection: some View {
        Section {
            LabeledContent("Saved Pictures") {
                Text(verbatim: "\(list.items.count)")
                    .monospacedDigit()
            }
            LabeledContent("Space Used") {
                Text(storageBytes, format: .byteCount(style: .file))
                    .monospacedDigit()
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
        }
    }

    private var watchSection: some View {
        Section {
            LabeledContent("Status", value: watchStatusText)
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Pictures received on Apple Watch come to this iPhone by themselves when the two are near each other.")
        }
    }

    private var otherSection: some View {
        Section {
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
            storageBytes = await Self.folderSize(ReceptionStore.root)
        }
    }

    /// Total size of the files under a folder, worked out off the main thread.
    private nonisolated static func folderSize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            folderSizeNow(url)
        }.value
    }

    private nonisolated static func folderSizeNow(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
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
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

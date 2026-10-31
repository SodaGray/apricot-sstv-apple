// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceiveView.swift
//  Apricot SSTV
//
//  The iPhone's receive screen, a system Form like Send, so corners,
//  margins and spacing come from the system. Every row is an ordinary
//  list row: a label on the left, its value on the right, and for the
//  two meters a bar under it (Meters.swift, shared with the watch).
//  Problems (no audio, too loud) show in red under the picture, other
//  notices in grey. Listen / Stop is at the top right, like
//  Send / Stop on the Send tab; receiving options are in the ⋯ menu at
//  the top left.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ReceiveView: View {
    @EnvironmentObject private var rx: Receiver
    @EnvironmentObject private var tx: Transmitter
    /// Pictures received now go into it (Events.swift).
    @State private var currentEvent: SSTVEvent?
    /// Decode Audio File: picking the file, then decoding it.
    @State private var pickingAudio = false
    @State private var decodingURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PictureView(image: rx.picture, status: rx.status)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else if let notice = rx.notice {
                        Text(notice)
                    }
                }

                Section("Signal") {
                    MeterRow(
                        title: "Tone",
                        value: toneValue,
                        bar: ToneMeter(toneHz: rx.isRunning ? rx.status?.toneHz : nil, showsScale: true)
                    )
                    MeterRow(
                        title: "Level",
                        value: levelValue,
                        valueColor: rx.clipping ? .red : .secondary,
                        bar: LevelMeter(db: rx.isRunning ? rx.levelDB : -120, clipping: rx.clipping, showsScale: true)
                    )
                }

                Section {
                    LabeledContent("Status", value: status)
                    LabeledContent("Mode", value: modeName)
                    if let s = rx.status, s.receiving {
                        LabeledContent("Rows", value: String(localized: "\(s.line) of \(s.height)"))
                    }
                    LabeledContent("Saved", value: "\(rx.savedCount)")
                    if let currentEvent, currentEvent.isCurrent() {
                        LabeledContent("Event", value: currentEvent.displayName)
                    }
                    // The receive timeout's last two minutes.
                    if let n = rx.stopsIn, rx.isRunning {
                        LabeledContent("Stops in", value: String(format: "%d:%02d", n / 60, n % 60))
                        Button("Keep Listening") { rx.keepListening() }
                    }
                }

                if let s = rx.status, s.mode != nil {
                    Section("Last picture") {
                        LabeledContent("Mode", value: "\(s.mode ?? "?") · \(s.start == .vis ? "VIS" : String(localized: "sync"))")
                        LabeledContent("Sender's clock", value: s.ppmValid ? "\(signed(s.ppm)) ppm" : String(localized: "Measuring"))
                        LabeledContent("Syncs found", value: s.syncPercent.map { "\($0)%" } ?? "—")
                        LabeledContent("Tuning offset", value: "\(signed(s.offsetHz)) Hz")
                    }
                }

                if rx.isRunning {
                    Section("Input") {
                        LabeledContent("Source", value: rx.inputName ?? String(localized: "Unknown"))
                        LabeledContent("Sample rate", value: String(format: "%.0f Hz", rx.sampleRate))
                        if rx.lostSeconds > 0.05 {
                            LabeledContent("Audio lost", value: String(format: "%.1f s", rx.lostSeconds))
                        }
                    }
                }
            }
            .monospacedDigit()
            .fileImporter(isPresented: $pickingAudio, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { decodingURL = url }
            }
            .sheet(isPresented: Binding(get: { decodingURL != nil }, set: { if !$0 { decodingURL = nil } })) {
                if let decodingURL {
                    DecodeAudioFileView(url: decodingURL, fullRate: rx.fullRateAudio)
                }
            }
            .onAppear { currentEvent = EventStore.current }
            .onReceive(NotificationCenter.default.publisher(for: .eventsChanged)) { _ in
                currentEvent = EventStore.current
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    optionsMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    listenButton
                }
            }
        }
    }

    // MARK: Buttons

    private var optionsMenu: some View {
        Menu {
            Picker(selection: $rx.chosenMode) {
                Text("Automatic").tag(Int?.none)
                Divider()
                ForEach(SSTVMode.all) { m in
                    Text(m.name).tag(Optional(m.vis))
                }
            } label: {
                Label("Mode", systemImage: "rectangle.on.rectangle")
                Text(modeName)
            }
            .pickerStyle(.menu)

            Section {
                Toggle(isOn: $rx.autosync) {
                    Label("Start Without VIS", systemImage: "dot.radiowaves.left.and.right")
                    if let chosenName {
                        Text("Lock on to \(chosenName) line syncs when the VIS header was missed.")
                    } else {
                        Text("Lock on to line syncs when the VIS header was missed.")
                    }
                }
            }
            Section {
                // A recording made elsewhere, decoded as if played to Receive
                // (AudioFileImport.swift). Not Settings → Import Library.
                Button {
                    pickingAudio = true
                } label: {
                    Label("Decode Audio File…", systemImage: "waveform")
                    Text("Find the pictures in a recording made elsewhere.")
                }
            }
            Section {
                Button(role: .destructive) {
                    rx.clearPicture()
                } label: {
                    Label("Clear Picture", systemImage: "xmark.rectangle")
                }
                .disabled(rx.picture == nil)
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
        }
    }

    /// Same as Send on the Send tab: a prominent word to start, a red one
    /// to stop.
    @ViewBuilder
    private var listenButton: some View {
        if rx.isRunning {
            Button("Stop", role: .destructive) {
                rx.stop()
            }
            .tint(.red)
        } else {
            Button("Start") {
                rx.start()
            }
            .buttonStyle(.glassProminent)
            .disabled(rx.isStarting || tx.isBusy)
        }
    }

    // MARK: Text

    private var status: String {
        if tx.isBusy { return String(localized: "Off while sending") }
        if rx.isStarting { return String(localized: "Starting…") }
        guard rx.isRunning else { return String(localized: "Off") }
        if let s = rx.status, s.receiving, let mode = s.mode { return String(localized: "Receiving \(mode)") }
        return String(localized: "Waiting for a picture")
    }

    /// Problems worth seeing at a glance, in red under the picture (in
    /// place of the latest notice).
    private var problem: String? {
        guard rx.isRunning else { return nil }
        if rx.stalled { return String(localized: "No audio is coming in.") }
        if rx.clipping { return String(localized: "Too loud: turn the radio down.") }
        return nil
    }

    /// The chosen mode's name, or nil for any mode.
    private var chosenName: String? {
        rx.chosenMode.flatMap { SSTVMode.byVIS($0)?.name }
    }

    private var modeName: String {
        chosenName.map { String(localized: "\($0) only") } ?? String(localized: "Automatic")
    }

    private var toneValue: String {
        guard rx.isRunning, let hz = rx.status?.toneHz else { return "—" }
        return "\(hz) Hz"
    }

    private var levelValue: String {
        guard rx.isRunning else { return "—" }
        if rx.clipping { return String(localized: "Clipping") }
        return rx.levelDB <= -119 ? "—" : String(format: "%.0f dB", rx.levelDB)
    }

    private func signed(_ n: Int) -> String {
        n > 0 ? "+\(n)" : "\(n)"
    }
}

// MARK: - Rows

/// A label and value like LabeledContent, with a bar under them.
private struct MeterRow<Bar: View>: View {
    let title: LocalizedStringKey
    let value: String
    var valueColor: Color = .secondary
    let bar: Bar

    var body: some View {
        VStack(spacing: 8) {
            LabeledContent(title) {
                Text(value).foregroundStyle(valueColor)
            }
            bar
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Picture

/// Edge to edge in its row: the list section gives it its corners.
private struct PictureView: View {
    let image: CGImage?
    let status: SSTVStatus?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color(.secondarySystemFill)
                    .aspectRatio(320.0 / 256.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text("No Picture Yet")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
            }

            if let status, status.receiving {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geo.size.width * status.progress, height: 3)
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image == nil ? Text("No picture yet") : Text("Received picture"))
    }
}


// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceiveView.swift
//  Apricot SSTV
//
//  The iPhone's receive screen, a system Form like Send, so corners,
//  margins and spacing come from the system. Every row is an ordinary
//  list row: a label on the left, its value on the right, and for the
//  two meters a bar under it. Listen / Stop is at the top right, like
//  Send / Stop on the Send tab; receiving options are in the ⋯ menu at
//  the top left.
//

import SwiftUI
import Combine

struct ReceiveView: View {
    @EnvironmentObject private var rx: Receiver
    @EnvironmentObject private var tx: Transmitter

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PictureView(image: rx.picture, status: rx.status)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if let warning {
                        Text(warning).foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("Status", value: status)
                LabeledContent("Mode", value: modeName)
                    if let s = rx.status, s.receiving {
                        LabeledContent("Rows", value: String(localized: "\(s.line) of \(s.height)"))
                    }
                    LabeledContent("Saved", value: "\(rx.savedCount)")
                }

                Section("Signal") {
                    MeterRow(
                        title: "Tone",
                        value: toneValue,
                        bar: TuningBar(toneHz: rx.isRunning ? rx.status?.toneHz : nil)
                    )
                    MeterRow(
                        title: "Level",
                        value: levelValue,
                        valueColor: rx.clipping ? .red : .secondary,
                        bar: LevelBar(db: rx.isRunning ? rx.levelDB : -120, clipping: rx.clipping)
                    )
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
            Button("Listen") {
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

    /// Problems worth seeing at a glance; other notices are in Status.
    private var warning: String? {
        guard rx.isRunning else { return rx.notice }
        if rx.stalled { return String(localized: "No audio is coming in.") }
        if rx.clipping { return String(localized: "Too loud: turn the radio down.") }
        return rx.notice
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

// MARK: - Bars

/// 1100–2400 Hz: sync (1200), black (1500), VIS leader (1900), white
/// (2300) as ticks; the live tone as a marker.
private struct TuningBar: View {
    let toneHz: Int?

    private static let lo = 1100.0
    private static let hi = 2400.0
    private static let marks: [Double] = [1200, 1500, 1900, 2300]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                ForEach(Self.marks, id: \.self) { hz in
                    Rectangle()
                        .fill(Color(.systemGray3))
                        .frame(width: 2)
                        .offset(x: x(hz, w))
                }
                if let toneHz {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 4)
                        .offset(x: x(Double(toneHz), w) - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func x(_ hz: Double, _ width: Double) -> Double {
        let t = (hz - Self.lo) / (Self.hi - Self.lo)
        return max(0, min(1, t)) * (width - 2)
    }
}

/// RMS level, −60 … 0 dBFS.
private struct LevelBar: View {
    let db: Double
    let clipping: Bool

    var body: some View {
        GeometryReader { geo in
            let t = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * t)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var color: Color {
        if clipping || db > -3 { return .red }
        if db > -12 { return .yellow }
        return .green
    }
}

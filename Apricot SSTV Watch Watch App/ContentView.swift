// SPDX-License-Identifier: GPL-3.0-only
//
//  ContentView.swift
//  Apricot SSTV Watch Watch App
//
//  Receive screen: the picture as it builds, what's being received,
//  a tuning bar and a level meter, and Listen / Stop.
//

import SwiftUI
import AVFAudio
import Combine

struct ContentView: View {
    @StateObject private var rx = Receiver()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        NavigationStack {
            receiveScreen
        }
    }

    private var receiveScreen: some View {
        ScrollView {
            VStack(spacing: 6) {
                PictureView(image: rx.picture, status: rx.status, isRunning: rx.isRunning)

                stateText

                if rx.isRunning {
                    TuningBar(toneHz: rx.status?.toneHz)
                    LevelMeter(db: rx.levelDB, clipping: rx.clipping)
                }

                Button {
                    rx.isRunning ? rx.stop() : rx.start()
                } label: {
                    Text(rx.isStarting ? LocalizedStringKey("Starting…") : rx.isRunning ? LocalizedStringKey("Stop") : LocalizedStringKey("Listen"))
                        .frame(maxWidth: .infinity)
                }
                .tint(rx.isRunning ? .red : .green)
                .disabled(rx.isStarting)

                details

                NavigationLink {
                    GalleryView()
                } label: {
                    Label("Pictures", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }

                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 2)
        }
        .onAppear { updateScene() }
        .onChange(of: scenePhase) { updateScene() }
        .onChange(of: isLuminanceReduced) { updateScene() }
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)
        ) { rx.handleInterruption($0) }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .AVAudioEngineConfigurationChange)
                .receive(on: DispatchQueue.main)
        ) { _ in rx.handleEngineConfigurationChange() }
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.mediaServicesWereResetNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in rx.handleMediaServicesReset() }
    }

    private func updateScene() {
        rx.setScene(
            visible: scenePhase != .background,
            active: scenePhase == .active && !isLuminanceReduced
        )
    }

    // MARK: State

    @ViewBuilder
    private var stateText: some View {
        VStack(spacing: 1) {
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub = subline {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(rx.stalled || rx.clipping ? .orange : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        guard rx.isRunning else { return String(localized: "Off") }
        guard let s = rx.status, s.receiving, let mode = s.mode else {
            return String(localized: "Listening")
        }
        return "\(mode) · \(s.start == .vis ? "VIS" : String(localized: "sync"))"
    }

    private var subline: String? {
        if rx.stalled { return String(localized: "No audio") }
        if let notice = rx.notice { return notice }
        guard rx.isRunning else { return nil }
        if rx.clipping { return String(localized: "Too loud: turn the radio down") }
        guard let s = rx.status, s.receiving else { return String(localized: "Waiting for VIS") }
        return String(localized: "RX \(s.line)/\(s.height)")
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 2) {
            if let s = rx.status, s.mode != nil {
                row("Clock", s.ppmValid ? "\(signed(s.ppm)) ppm" : "?")
                row("Sync", s.syncPercent.map { "\($0)%" } ?? "—")
                row("Offset", "\(signed(s.offsetHz)) Hz")
            }
            row("Saved", "\(rx.savedCount)")
            if rx.lostSeconds > 0.05 {
                row("Lost", String(format: "%.1f s", rx.lostSeconds))
            }
        }
        .padding(.top, 2)
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

// MARK: - Picture

private struct PictureView: View {
    let image: CGImage?
    let status: SSTVStatus?
    let isRunning: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.08))
                    .aspectRatio(320.0 / 256.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 2) {
                            Text("Apricot SSTV")
                                .font(.system(size: 13, weight: .semibold))
                            Text(isRunning ? LocalizedStringKey("Listening…") : LocalizedStringKey("Tap Listen"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            if let status, status.receiving {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.green)
                        .frame(width: geo.size.width * status.progress, height: 2)
                }
                .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Tuning bar

/// 1100–2400 Hz, marks at sync (1200), black (1500), VIS leader (1900)
/// and white (2300); the cursor is the live tone.
private struct TuningBar: View {
    let toneHz: Int?

    private static let lo = 1100.0
    private static let hi = 2400.0
    private static let marks: [Double] = [1200, 1500, 1900, 2300]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.15))
                ForEach(Self.marks, id: \.self) { hz in
                    Rectangle()
                        .fill(hz == 1200 ? Color.blue : Color.gray)
                        .frame(width: 1.5)
                        .offset(x: x(hz, w))
                }
                if let toneHz {
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 3)
                        .offset(x: x(Double(toneHz), w) - 0.75)
                }
            }
        }
        .frame(height: 7)
    }

    private func x(_ hz: Double, _ width: Double) -> Double {
        let t = (hz - Self.lo) / (Self.hi - Self.lo)
        return max(0, min(1, t)) * (width - 2)
    }
}

// MARK: - Level meter

/// RMS level, −60 … 0 dBFS.
private struct LevelMeter: View {
    let db: Double
    let clipping: Bool

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                let t = max(0, min(1, (db + 60) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * t)
                }
            }
            .frame(height: 5)

            Group {
                if clipping {
                    Text("CLIP")
                } else {
                    Text(verbatim: String(format: "%.0f dB", db))
                }
            }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(clipping ? .red : .secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var color: Color {
        if clipping || db > -3 { return .red }
        if db > -12 { return .yellow }
        return .green
    }
}

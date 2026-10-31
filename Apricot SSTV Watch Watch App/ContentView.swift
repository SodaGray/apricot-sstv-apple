// SPDX-License-Identifier: GPL-3.0-only
//
//  ContentView.swift
//  Apricot SSTV Watch Watch App
//
//  Receive screen: the picture as it builds, what's being received,
//  the tone and level meters (Meters.swift), and Listen / Stop. With the
//  wrist down (screen dimmed) the meters are hidden and the picture is
//  redrawn once a second, together with the rows and the progress, so it
//  never looks stuck. When listening stopped by itself, the reason stays
//  on screen with a way to keep it from happening again; in the timeout's
//  last two minutes, a countdown and Keep Listening.
//

import SwiftUI
import AVFAudio
import Combine

struct ContentView: View {
    @StateObject private var rx = Receiver()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage("onboarding.done") private var onboardingDone = false
    /// The iPhone's current event: pictures received now go into it.
    @AppStorage(CurrentEventInfo.nameKey) private var eventName = ""
    @AppStorage(CurrentEventInfo.untilKey) private var eventUntil: Double = 0

    var body: some View {
        NavigationStack {
            receiveScreen
        }
        // First launch: what it does, and the two choices.
        .fullScreenCover(isPresented: .constant(!onboardingDone)) {
            OnboardingView(purpose: .firstLaunch, rx: rx)
        }
    }

    private var receiveScreen: some View {
        ScrollView {
            VStack(spacing: 6) {
                // Tapping the picture starts listening (a big target on a
                // small screen); it never stops it: that's only the Stop
                // button, so a touch while receiving can't end a picture.
                PictureView(image: rx.picture, status: rx.status, isRunning: rx.isRunning)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !rx.isRunning && !rx.isStarting { rx.start() }
                    }
                    .accessibilityAddTraits(rx.isRunning ? [] : .isButton)

                stateText

                if !eventName.isEmpty, Date.now.timeIntervalSince1970 < eventUntil {
                    Label(eventName, systemImage: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(Text("Event: \(eventName)"))
                }

                // The timeout is about to stop listening: put it off.
                if rx.isRunning, rx.stopsIn != nil {
                    Button("Keep Listening") { rx.keepListening() }
                        .controlSize(.small)
                }

                if rx.isRunning && !isLuminanceReduced {
                    meters
                }

                Button {
                    rx.isRunning ? rx.stop() : rx.start()
                } label: {
                    Text(rx.isStarting ? LocalizedStringKey("Starting…") : rx.isRunning ? LocalizedStringKey("Stop") : LocalizedStringKey("Listen"))
                        .frame(maxWidth: .infinity)
                }
                .tint(rx.isRunning ? Color.red : Color.accentColor)
                .disabled(rx.isStarting)

                // Stopped because the wrist went down or the app was left:
                // say so, and offer to stop doing that.
                if !rx.isRunning, let reason = rx.stoppedBy, reason != .timeout {
                    Button {
                        rx.wristPolicy = .keep
                        rx.start()
                    } label: {
                        Text("Listen, and Keep Listening with Wrist Down")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.system(size: 13))
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                }

                details

                NavigationLink {
                    GalleryView()
                } label: {
                    Label("Pictures", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }

                NavigationLink {
                    SettingsView(rx: rx)
                } label: {
                    Label("Settings", systemImage: "gearshape")
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
                    .foregroundStyle(rx.clipping ? .red : rx.stalled ? .yellow : .secondary)
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
        if let n = rx.stopsIn, rx.isRunning {
            let time = String(format: "%d:%02d", n / 60, n % 60)
            return String(localized: "No picture: stops in \(time)")
        }
        if let notice = rx.notice { return notice }
        guard rx.isRunning else { return nil }
        if rx.clipping { return String(localized: "Too loud: turn the radio down") }
        guard let s = rx.status, s.receiving else { return rx.waitingText }
        return String(localized: "RX \(s.line)/\(s.height)")
    }

    // MARK: Meters

    /// The same as on the iPhone: name and reading above, bar below.
    private var meters: some View {
        VStack(spacing: 4) {
            meterLabel("Tone", toneValue)
            ToneMeter(toneHz: rx.status?.toneHz)
            meterLabel("Level", levelValue, color: rx.clipping ? .red : .secondary)
                .padding(.top, 2)
            LevelMeter(db: rx.levelDB, clipping: rx.clipping)
        }
        .padding(.vertical, 2)
    }

    private var toneValue: String {
        guard let hz = rx.status?.toneHz else { return "—" }
        return "\(hz) Hz"
    }

    private var levelValue: String {
        if rx.clipping { return String(localized: "CLIP") }
        return rx.levelDB <= -119 ? "—" : String(format: "%.0f dB", rx.levelDB)
    }

    private func meterLabel(_ title: LocalizedStringKey, _ value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.system(size: 11))
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
                            Text(isRunning ? LocalizedStringKey("Listening…") : LocalizedStringKey("Tap to Listen"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            if let status, status.receiving {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geo.size.width * status.progress, height: 2)
                }
                .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// SPDX-License-Identifier: GPL-3.0-only
//
//  ContentView.swift
//  Apricot SSTV
//
//  Four tabs: Receive, Send, Pictures, Settings. The receiver and transmitter
//  live here, above the tabs, so a picture keeps coming in while you
//  look at another tab, and sending can stop receiving first.
//
//  The haptics for starting, stopping and finishing are here, so they
//  play whichever tab is showing.
//
//  Every tab uses the standard large title (as in Messages): buttons on
//  the bar above it, and on scrolling the large title slides up and out
//  while the small one fades in. The main action of Receive and Send
//  (Listen / Send, and Stop) is the button at the top right.
//
//  Haptics: SensoryFeedback's .start and .stop only play on watchOS, so
//  the iPhone uses impacts: heavy for start, light for stop. (A VIS
//  heard mid-listen is a medium impact, from Receiver.)
//

import SwiftUI
import AVFAudio
import Combine

enum AppTab: Hashable {
    case receive, send, pictures, settings
}

struct ContentView: View {
    @StateObject private var receiver = Receiver()
    @StateObject private var transmitter = Transmitter()
    @State private var tab: AppTab = .receive
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            Tab("Receive", systemImage: "antenna.radiowaves.left.and.right", value: AppTab.receive) {
                ReceiveView()
            }
            Tab("Send", systemImage: "paperplane", value: AppTab.send) {
                SendView()
            }
            Tab("Pictures", systemImage: "photo.on.rectangle", value: AppTab.pictures) {
                GalleryView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .environmentObject(receiver)
        .environmentObject(transmitter)
        // Listening started / stopped.
        .sensoryFeedback(trigger: receiver.isRunning) { _, running in
            running ? .impact(weight: .heavy) : .impact(weight: .light)
        }
        // Sending started / ended, and how it ended.
        .sensoryFeedback(trigger: transmitter.state) { old, new in
            switch (old, new) {
            case (.encoding, .sending):
                return .impact(weight: .heavy)
            case (_, .idle):
                switch transmitter.lastOutcome {
                case .sent: return .success
                case .stopped: return .impact(weight: .light)
                case .failed: return .error
                case nil: return nil
                }
            default:
                return nil
            }
        }
        .onAppear { updateScene() }
        .onChange(of: scenePhase) { updateScene() }
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)
        ) { note in
            receiver.handleInterruption(note)
            transmitter.handleInterruption(note)
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .AVAudioEngineConfigurationChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            receiver.handleEngineConfigurationChange()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.mediaServicesWereResetNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            receiver.handleMediaServicesReset()
            transmitter.handleMediaServicesReset()
        }
    }

    private func updateScene() {
        receiver.setScene(
            visible: scenePhase != .background,
            active: scenePhase == .active
        )
    }
}

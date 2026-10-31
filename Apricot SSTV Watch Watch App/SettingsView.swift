// SPDX-License-Identifier: GPL-3.0-only
//
//  SettingsView.swift
//  Apricot SSTV Watch Watch App
//
//  The watch's own settings (the iPhone keeps its own): the mode to
//  receive, starting without VIS, what lowering the wrist does, the
//  receive timeout, and saving raw audio; and the introduction again.
//

import SwiftUI
import Combine

struct SettingsView: View {
    @ObservedObject var rx: Receiver

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $rx.chosenMode) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(ModeChoice.all) { m in
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
                Picker("Wrist Down", selection: $rx.wristPolicy) {
                    ForEach(WristPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
            } footer: {
                Text(rx.wristPolicy.explanation)
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
            } footer: {
                Text("Keeps the sound of each picture and sends it to the iPhone with the picture.")
            }

            Section {
                NavigationLink {
                    OnboardingView(purpose: .review, rx: rx)
                } label: {
                    Label("Introduction", systemImage: "sparkles")
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func timeoutTitle(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "Never") : String(localized: "\(minutes) min")
    }
}

/// The modes the decoder handles, in the iPhone's order.
private struct ModeChoice: Identifiable {
    let vis: Int
    let name: String
    var id: Int { vis }

    static let all: [ModeChoice] = [8, 12, 44, 40, 60, 56, 76, 93, 99, 95, 98, 96, 97, 94]
        .compactMap { vis in
            SSTVDecoder.modeName(vis: vis).map { ModeChoice(vis: vis, name: $0) }
        }
}

extension WristPolicy {
    var title: String {
        switch self {
        case .stop: String(localized: "Stop Listening")
        case .keepWhenDimmed: String(localized: "Keep While Dimmed")
        case .keep: String(localized: "Keep Listening")
        }
    }

    var explanation: String {
        switch self {
        case .stop:
            String(localized: "When the screen dims or you leave the app, listening stops, after the picture coming in. Saves the most battery.")
        case .keepWhenDimmed:
            String(localized: "Listening carries on with the wrist down, and stops when you leave the app, after the picture coming in.")
        case .keep:
            String(localized: "Listening carries on until you tap Stop, with the wrist down or in another app.")
        }
    }
}

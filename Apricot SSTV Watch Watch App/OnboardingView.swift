// SPDX-License-Identifier: GPL-3.0-only
//
//  OnboardingView.swift
//  Apricot SSTV Watch Watch App
//
//  First launch on the watch, one screen at a time: what it does, then
//  the two choices that change how it works (lowering the wrist, raw
//  audio). A choice can't be skipped: the next screen comes only from
//  picking one. The watch keeps its own settings, so it asks even if the
//  iPhone already did. Settings → Introduction shows them again with the
//  current choices ticked.
//

import SwiftUI
import Combine

struct OnboardingView: View {
    enum Purpose { case firstLaunch, review }

    let purpose: Purpose
    @ObservedObject var rx: Receiver

    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding.done") private var done = false
    @State private var step = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch step {
                case 0: welcome
                case 1: wristChoice
                default: audioChoice
                }
            }
            .padding(.horizontal, 4)
        }
        .animation(.default, value: step)
    }

    // MARK: Screens

    private var welcome: some View {
        Group {
            Text(verbatim: AppInfo.name)
                .font(.title3.bold())
            Text("Receive slow-scan television pictures from your radio. They go to your iPhone by themselves.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                step = 1
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .tint(.accentColor)
            .padding(.top, 4)
        }
    }

    private var wristChoice: some View {
        Group {
            Text("Wrist Down")
                .font(.headline)
            Text("After you tap Listen and lower your wrist:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            choice(
                "Keep Listening",
                "Until you tap Stop, or no picture comes for the receive timeout.",
                selected: purpose == .review && rx.wristPolicy != .stop
            ) {
                rx.wristPolicy = .keep
                step = 2
            }
            choice(
                "Stop Listening",
                "Saves the most battery. A picture coming in is finished first.",
                selected: purpose == .review && rx.wristPolicy == .stop
            ) {
                rx.wristPolicy = .stop
                step = 2
            }
        }
    }

    private var audioChoice: some View {
        Group {
            Text("Raw Audio")
                .font(.headline)
            Text("Keep each picture's sound. It goes to the iPhone with the picture, where a bad one can be developed again from it in the darkroom.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            choice("Save Raw Audio", "About 8 MB for a Martin M1 picture.", selected: purpose == .review && rx.saveAudio) {
                rx.saveAudio = true
                finish()
            }
            choice("Pictures Only", "Uses the least space.", selected: purpose == .review && !rx.saveAudio) {
                rx.saveAudio = false
                finish()
            }
            Text("You can change these in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func choice(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Several lines don't fit a capsule's round ends.
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private func finish() {
        if purpose == .firstLaunch {
            done = true             // ContentView's cover closes on this
        } else {
            dismiss()
        }
    }
}

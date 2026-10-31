// SPDX-License-Identifier: GPL-3.0-only
//
//  OnboardingView.swift
//  Apricot SSTV
//
//  Two pages on first launch: what the app does, then the one choice that
//  changes how it works (keep each picture's raw audio or not). The choice
//  isn't made for you: Start stays off until one is picked. Settings →
//  Introduction shows the same pages again, with the current choice
//  ticked; looking changes nothing.
//

import SwiftUI
import Combine

struct OnboardingView: View {
    enum Purpose { case firstLaunch, review }

    let purpose: Purpose

    @EnvironmentObject private var rx: Receiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding.done") private var done = false
    @State private var page = 0
    /// nil until picked (first launch).
    @State private var saveAudio: Bool?

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                welcomePage.tag(0)
                audioPage.tag(1)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .safeAreaInset(edge: .bottom) { bottomButton }
            .toolbar {
                if purpose == .review {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(purpose == .firstLaunch)
        .onAppear {
            if purpose == .review { saveAudio = rx.saveAudio }
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: AppInfo.name)
                        .font(.largeTitle.bold())
                    Text("Slow-scan television on iPhone and Apple Watch.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                FeatureRow(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "Receive",
                    text: "Pictures from your radio, through the microphone or a USB audio interface. Apple Watch can receive on its own, and its pictures come to this iPhone."
                )
                FeatureRow(
                    systemImage: "paperplane",
                    title: "Send",
                    text: "Put a photo in the frame, add your callsign, and send it through your radio."
                )
                FeatureRow(
                    systemImage: "wand.and.stars",
                    title: "Darkroom",
                    text: "A picture can keep the sound it was decoded from. A bad one is then developed again from that sound, not bent or retouched as an image: every pixel still comes from the signal."
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var audioPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keep Raw Audio?")
                        .font(.largeTitle.bold())
                    Text("Each picture's sound, from as long before it to as long after it as the picture takes to send, in case its start or end was misjudged. If a picture comes out badly, it can be developed again from this sound in the darkroom, or the sound shared. Without it, only the picture is left.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                VStack(spacing: 12) {
                    ChoiceCard(
                        title: "Save Raw Audio",
                        text: "About 8 MB for a Martin M1 picture.",
                        isSelected: saveAudio == true
                    ) { saveAudio = true }
                    ChoiceCard(
                        title: "Pictures Only",
                        text: "Uses the least space.",
                        isSelected: saveAudio == false
                    ) { saveAudio = false }
                }

                Text("You can change this in Settings at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Button

    @ViewBuilder
    private var bottomButton: some View {
        Group {
            if page == 0 {
                Button {
                    withAnimation { page = 1 }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    finish()
                } label: {
                    Text(purpose == .firstLaunch ? LocalizedStringKey("Get Started") : LocalizedStringKey("Done"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(saveAudio == nil)
            }
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
    }

    private func finish() {
        guard let saveAudio else { return }
        rx.saveAudio = saveAudio
        if purpose == .firstLaunch {
            done = true             // ContentView's cover closes on this
        } else {
            dismiss()
        }
    }
}

// MARK: - Parts

private struct FeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

/// One answer to a question: a card that shows when it's the one picked.
private struct ChoiceCard: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

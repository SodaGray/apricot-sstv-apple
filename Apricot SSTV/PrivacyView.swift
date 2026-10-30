// SPDX-License-Identifier: GPL-3.0-only
//
//  PrivacyView.swift
//  Apricot SSTV
//
//  The privacy policy, in the app. The same words are on the web at
//  AppInfo.privacyPolicy, for the App Store listing; change both together.
//

import SwiftUI

struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apricot SSTV collects no data.")
                        .font(.title3.weight(.semibold))
                    Text("Updated \(AppInfo.privacyDate.formatted(date: .long, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Nothing about you, your pictures or how you use the app is collected, sent to the developer, or shared with anyone.")
            }

            Section("On Your Devices") {
                Text("The pictures you receive, their details, and your settings (such as the mode and your callsign) are kept only in the app on your iPhone and Apple Watch. Deleting a picture, or the app, removes them.")
            }

            Section("Microphone") {
                Text("Used only while Listen is on, to decode pictures as they arrive. The sound isn't recorded, saved or sent anywhere.")
            }

            Section("Photos") {
                Text("Only the photo you choose to send is read, to make the picture; Apricot SSTV can't see the rest of your library. A picture is added to Photos only when you save it.")
            }

            Section("Apple Watch") {
                Text("Pictures go from your watch to your iPhone directly, over Apple's own connection between the two. They don't pass through any server of ours.")
            }

            Section("No Tracking") {
                Text("No ads, no analytics, no accounts and no third-party code. The app makes no internet connections of its own; a link you tap opens in Safari.")
            }

            Section {
                Link(destination: AppInfo.website) {
                    LabeledContent("Website") {
                        Text(verbatim: AppInfo.websiteText)
                    }
                }
            } header: {
                Text("Questions")
            } footer: {
                Text("If this policy ever changes, the new version will be in the app and on the website before it applies.")
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

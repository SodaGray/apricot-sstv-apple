// SPDX-License-Identifier: GPL-3.0-only
//
//  AboutView.swift
//  Apricot SSTV
//
//  About Apricot SSTV: version, what it does, the privacy promise, the
//  licence and where the source is, and the modes it handles. Opened
//  from Settings.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    Text(verbatim: AppInfo.name)
                        .font(.title.weight(.bold))
                    Text("Version \(AppInfo.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("By \(AppInfo.author)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Label("Nothing is collected or sent anywhere.", systemImage: "lock")
                WebLink("Privacy Policy", systemImage: "hand.raised", destination: AppInfo.privacyPolicy)
            } header: {
                Text("Privacy")
            }

            Section {
                Link(destination: AppInfo.website) {
                    LabeledContent("Website") {
                        Text(verbatim: AppInfo.websiteText)
                    }
                }
                Link(destination: AppInfo.source) {
                    LabeledContent("Source Code") {
                        Text(verbatim: AppInfo.sourceText)
                    }
                }
                Link(destination: AppInfo.ipodSource) {
                    LabeledContent("iPod nano Version") {
                        Text(verbatim: AppInfo.ipodSourceText)
                    }
                }
                Link(destination: AppInfo.license) {
                    LabeledContent("License") {
                        Text(verbatim: "GNU GPL v3")
                    }
                }
            } header: {
                Text("Free Software")
            } footer: {
                Text("© \(AppInfo.year) \(AppInfo.author). Apricot SSTV is free software: you can redistribute it and modify it under the terms of the GNU General Public License, version 3. It comes with no warranty. Its decoder began as Apricot SSTV for the iPod nano.")
            }

            Section {
                ForEach(SSTVMode.all) { mode in
                    LabeledContent {
                        Text(verbatim: mode.lengthText)
                            .monospacedDigit()
                    } label: {
                        Text(verbatim: mode.name)
                    }
                }
            } header: {
                Text("Modes")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

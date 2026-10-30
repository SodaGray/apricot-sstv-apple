// SPDX-License-Identifier: GPL-3.0-only
//
//  AboutView.swift
//  Apricot SSTV Watch Watch App
//
//  The short version of the iPhone's About screen. No links (a watch has
//  no browser); the addresses are shown as text.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: AppInfo.name)
                    .font(.headline)
                Text("Version \(AppInfo.version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("By \(AppInfo.author)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Apricot SSTV collects no data.")
                    .font(.footnote.weight(.semibold))
                Text("No ads, no account. Nothing is collected or sent anywhere; pictures only move between your watch and your iPhone.")
                    .font(.footnote)

                Divider()

                Text("Free software under the GNU GPL v3, with no warranty.")
                    .font(.footnote)
                Text(verbatim: AppInfo.websiteText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: AppInfo.sourceText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("About")
    }
}

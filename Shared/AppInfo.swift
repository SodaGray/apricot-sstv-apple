// SPDX-License-Identifier: GPL-3.0-only
//
//  AppInfo.swift
//  What the About screens show, in one place for the iPhone and the watch.
//

import Foundation

nonisolated enum AppInfo {
    static let name = "Apricot SSTV"

    /// "1.0 (1)", from the app bundle.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The author: 苏打灰 in Chinese, SodaGray in English.
    static var author: String { String(localized: "SodaGray", comment: "The author's name") }
    static let year = "2026"

    static let websiteText = "bd1fpn.cn"
    static let website = URL(string: "https://bd1fpn.cn/")!

    /// The iPhone / Watch source (GPL v3: anyone who has the app may have
    /// its source). The iPod version is a separate repository.
    static let sourceText = "github.com/SodaGray/apricot-sstv-apple"
    static let source = URL(string: "https://github.com/SodaGray/apricot-sstv-apple")!
    static let ipodSourceText = "github.com/SodaGray/apricot-sstv"
    static let ipodSource = URL(string: "https://github.com/SodaGray/apricot-sstv")!

    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    /// The privacy policy: one page on the website, linked from Settings
    /// and About, and given to App Store Connect.
    static let privacyPolicy = URL(string: "https://bd1fpn.cn/apricot/privacy.html")!
}

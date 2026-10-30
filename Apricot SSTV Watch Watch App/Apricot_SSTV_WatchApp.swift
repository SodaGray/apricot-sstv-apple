//
//  Apricot_SSTV_WatchApp.swift
//  Apricot SSTV Watch Watch App
//
//  Created by Cherry on 2026/10/29.
//

import SwiftUI

@main
struct Apricot_SSTV_Watch_Watch_AppApp: App {
    init() { WatchSync.shared.activate() }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

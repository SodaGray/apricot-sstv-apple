//
//  Apricot_SSTVApp.swift
//  Apricot SSTV
//
//  Created by Cherry on 2026/10/29.
//

import SwiftUI

@main
struct Apricot_SSTVApp: App {
    init() { PhoneSync.shared.activate() }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

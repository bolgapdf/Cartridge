//
//  CartridgeApp.swift
//  Cartridge
//

import SwiftUI

@main
struct CartridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        // The screen is 160×144, so anything is a scale factor. Locking the
        // window to that ratio keeps whole pixels whole.
        .windowResizability(.contentSize)
        #endif
    }
}

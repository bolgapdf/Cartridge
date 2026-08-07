//
//  CartridgeApp.swift
//  Cartridge
//

import SwiftUI

@main
struct CartridgeApp: App {

    init() {
        // Registered rather than left to each reader's own default. `@AppStorage`
        // supplies one until the switch is touched, but code outside a view
        // reading `bool(forKey:)` would get `false` for a key that was never
        // written — so a setting nobody has changed would already be off.
        UserDefaults.standard.register(defaults: ["autoResume": true])
    }

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

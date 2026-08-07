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
        // A floor rather than a fixed size. `.contentSize` pinned the window to
        // whatever the layout asked for, which for a library that's mostly
        // flexible space is not a useful answer.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 640)
        #endif
    }
}

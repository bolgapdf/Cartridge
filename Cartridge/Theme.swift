//
//  Theme.swift
//  Cartridge
//

import SwiftUI

/// The colour of the room the library sits in.
///
/// Split from the buttons deliberately: the two are unrelated choices, and
/// forcing them to move together means neither can be what you want.
struct ShellTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let top: Color
    let bottom: Color
    let card: Color
    let border: Color
    /// Cards become frosted glass rather than a flat fill. Only the clear
    /// theme uses it, and it's the whole point of that theme.
    let frosted: Bool
    /// Which way the text has to go. Set explicitly rather than derived from
    /// the background, because a mid grey is genuinely ambiguous.
    let dark: Bool

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var scheme: ColorScheme { dark ? .dark : .light }

    /// The original 1989 shell: a warm grey that everyone remembers as white
    /// and no surviving unit still is.
    static let gameBoy = ShellTheme(
        id: "gameboy", name: "Game Boy",
        top: Color(red: 0.90, green: 0.89, blue: 0.86),
        bottom: Color(red: 0.75, green: 0.74, blue: 0.71),
        card: Color(red: 0.95, green: 0.95, blue: 0.93),
        border: .black.opacity(0.10), frosted: false, dark: false
    )

    /// Desktop beige, and specifically the yellowed kind — the colour those
    /// machines became rather than the colour they left the factory.
    static let beige = ShellTheme(
        id: "beige", name: "Beige",
        top: Color(red: 0.91, green: 0.88, blue: 0.78),
        bottom: Color(red: 0.78, green: 0.74, blue: 0.60),
        card: Color(red: 0.96, green: 0.94, blue: 0.87),
        border: Color(red: 0.45, green: 0.40, blue: 0.28).opacity(0.22),
        frosted: false, dark: false
    )

    /// The clear shells, where the appeal was seeing the board through them.
    static let clear = ShellTheme(
        id: "clear", name: "Clear",
        top: Color(red: 0.87, green: 0.94, blue: 0.94),
        bottom: Color(red: 0.68, green: 0.82, blue: 0.83),
        card: .white.opacity(0.30),
        border: .white.opacity(0.55), frosted: true, dark: false
    )

    static let light = ShellTheme(
        id: "light", name: "Bright",
        top: Color(white: 0.99),
        bottom: Color(red: 0.90, green: 0.93, blue: 0.96),
        card: .white,
        border: .black.opacity(0.07), frosted: false, dark: false
    )

    static let midnight = ShellTheme(
        id: "midnight", name: "Midnight",
        top: Color(white: 0.13),
        bottom: Color(white: 0.05),
        card: Color(white: 0.16),
        border: .white.opacity(0.08), frosted: false, dark: true
    )

    static let all: [ShellTheme] = [gameBoy, beige, clear, light, midnight]

    static func named(_ id: String) -> ShellTheme {
        all.first { $0.id == id } ?? gameBoy
    }
}

/// The colour of the controls.
struct ButtonTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let pad: Color
    let face: Color
    let pill: Color
    let label: Color

    /// Pressed states are derived rather than specified. A button lightening
    /// under a thumb is one idea, and writing it out twice per colour is three
    /// chances to get it inconsistent.
    var padPressed: Color { pad.mixed(with: .white, by: 0.18) }
    var facePressed: Color { face.mixed(with: .white, by: 0.22) }
    var pillPressed: Color { pill.mixed(with: .white, by: 0.22) }

    /// The DMG: near-black cross, magenta buttons, grey slabs.
    static let classic = ButtonTheme(
        id: "classic", name: "Classic",
        pad: Color(red: 0.13, green: 0.13, blue: 0.15),
        face: Color(red: 0.60, green: 0.13, blue: 0.32),
        pill: Color(red: 0.42, green: 0.42, blue: 0.47),
        label: .white.opacity(0.92)
    )

    static let clear = ButtonTheme(
        id: "clear", name: "Clear",
        pad: Color(red: 0.78, green: 0.86, blue: 0.86).opacity(0.35),
        face: Color(red: 0.70, green: 0.90, blue: 0.88).opacity(0.45),
        pill: .white.opacity(0.30),
        label: .white.opacity(0.95)
    )

    static let charcoal = ButtonTheme(
        id: "charcoal", name: "Charcoal",
        pad: Color(white: 0.16),
        face: Color(white: 0.30),
        pill: Color(white: 0.24),
        label: .white.opacity(0.85)
    )

    static let indigo = ButtonTheme(
        id: "indigo", name: "Indigo",
        pad: Color(red: 0.12, green: 0.13, blue: 0.22),
        face: Color(red: 0.29, green: 0.31, blue: 0.72),
        pill: Color(red: 0.32, green: 0.34, blue: 0.44),
        label: .white.opacity(0.94)
    )

    static let kiwi = ButtonTheme(
        id: "kiwi", name: "Kiwi",
        pad: Color(red: 0.12, green: 0.16, blue: 0.12),
        face: Color(red: 0.36, green: 0.60, blue: 0.20),
        pill: Color(red: 0.34, green: 0.40, blue: 0.32),
        label: .white.opacity(0.94)
    )

    static let all: [ButtonTheme] = [classic, clear, charcoal, indigo, kiwi]

    static func named(_ id: String) -> ButtonTheme {
        all.first { $0.id == id } ?? classic
    }
}

extension Color {
    /// A blend towards another colour, for deriving pressed states.
    func mixed(with other: Color, by amount: Double) -> Color {
        // `Color.mix(with:by:)` exists on the newest systems only; this keeps
        // one behaviour everywhere the app runs.
        Color(
            .displayP3,
            red: components.red + (other.components.red - components.red) * amount,
            green: components.green + (other.components.green - components.green) * amount,
            blue: components.blue + (other.components.blue - components.blue) * amount,
            opacity: components.alpha
        )
    }

    private var components: (red: Double, green: Double, blue: Double, alpha: Double) {
        #if os(macOS)
        let native = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        return (Double(native.redComponent), Double(native.greenComponent),
                Double(native.blueComponent), Double(native.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}

// MARK: - Access

/// Both themes are read straight from storage wherever they're needed rather
/// than threaded through every view. They're app-wide settings that change
/// rarely, and passing them down by hand would touch a dozen initialisers to
/// say something every one of those views could simply ask.
@propertyWrapper
struct ThemeSetting: DynamicProperty {
    @AppStorage("shellTheme") private var shellID = ShellTheme.gameBoy.id
    @AppStorage("buttonTheme") private var buttonID = ButtonTheme.classic.id

    var wrappedValue: (shell: ShellTheme, buttons: ButtonTheme) {
        (.named(shellID), .named(buttonID))
    }
}

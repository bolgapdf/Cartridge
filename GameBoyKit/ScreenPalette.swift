//
//  ScreenPalette.swift
//  GameBoyKit
//

import Foundation

/// The four shades a monochrome Game Boy can display.
///
/// The hardware has no colour at all — it produces two bits per pixel and the
/// screen decides what those look like. So a palette isn't a filter over a
/// "real" image; it's the same choice the physical panel was making.
///
/// The first three below are modelled on actual hardware. The rest are simply
/// nice, and don't pretend otherwise.
public struct ScreenPalette: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Lightest first — the order the two-bit colour index uses.
    public let shades: [UInt32]

    public init(id: String, name: String, shades: [UInt32]) {
        self.id = id
        self.name = name
        self.shades = shades
    }

    // MARK: - Hardware

    /// The original 1989 DMG: a green LCD, not a grey one showing green.
    public static let dmg = ScreenPalette(
        id: "dmg", name: "Game Boy",
        shades: [0xFF_9BBC0F, 0xFF_8BAC0F, 0xFF_306230, 0xFF_0F380F]
    )

    /// The Pocket dropped the green for a much higher-contrast grey panel,
    /// which is why its screen is the one people remember as readable.
    public static let pocket = ScreenPalette(
        id: "pocket", name: "Pocket",
        shades: [0xFF_E8E8E8, 0xFF_A0A0A0, 0xFF_585858, 0xFF_101010]
    )

    /// The Light's backlight was a distinctly blue-green glow rather than white.
    public static let light = ScreenPalette(
        id: "light", name: "Light",
        shades: [0xFF_00B588, 0xFF_009A70, 0xFF_00694A, 0xFF_004F3B]
    )

    // MARK: - Chosen

    public static let ice = ScreenPalette(
        id: "ice", name: "Ice",
        shades: [0xFF_DFF6FF, 0xFF_8EC5E0, 0xFF_3A6EA5, 0xFF_10243E]
    )

    public static let ember = ScreenPalette(
        id: "ember", name: "Ember",
        shades: [0xFF_FFE8C8, 0xFF_E8A33D, 0xFF_9B3B1E, 0xFF_2B0F0A]
    )

    public static let grape = ScreenPalette(
        id: "grape", name: "Grape",
        shades: [0xFF_F2E6FF, 0xFF_B98CE0, 0xFF_6B3FA0, 0xFF_25123F]
    )

    /// No tint at all, for reading text.
    public static let mono = ScreenPalette(
        id: "mono", name: "Mono",
        shades: [0xFF_FFFFFF, 0xFF_AAAAAA, 0xFF_555555, 0xFF_000000]
    )

    public static let all: [ScreenPalette] = [dmg, pocket, light, ice, ember, grape, mono]

    public static func named(_ id: String) -> ScreenPalette {
        all.first { $0.id == id } ?? .dmg
    }
}

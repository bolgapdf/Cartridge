//
//  Joypad.swift
//  GameBoyKit
//

import Foundation

/// Eight buttons behind a four-bit port.
///
/// The register at 0xFF00 doesn't report all eight at once. Two select lines
/// choose whether the low nibble reads the d-pad or the four face buttons, and
/// a game reads the port twice per frame with different selects. Pressed reads
/// as **zero**, because the buttons short the line to ground.
final class Joypad: Codable {
    /// Bits 0–3 are right, left, up, down; bits 4–7 are A, B, select, start.
    /// Set means pressed, which is the inverse of what the port reports.
    private var pressed: UInt8 = 0
    /// The two select lines, as written by the game.
    private var selection: UInt8 = 0x30

    func set(_ button: ConsoleButton, pressed isDown: Bool) -> Bool {
        guard let bit = Self.bit(for: button) else { return false }

        let before = read()
        if isDown { pressed |= bit } else { pressed &= ~bit }

        // The interrupt fires on any selected line going low. It's essentially
        // unused — every game polls instead — but it's also the only thing that
        // can wake a game that halted to save battery.
        return before & 0x0F != read() & 0x0F && isDown
    }

    func write(_ value: UInt8) {
        selection = value & 0x30
    }

    func read() -> UInt8 {
        var lines: UInt8 = 0x0F
        // A select line is active when it's *low*, which reads backwards
        // everywhere it appears.
        if selection & 0x10 == 0 { lines &= ~(pressed & 0x0F) }
        if selection & 0x20 == 0 { lines &= ~(pressed >> 4) }
        // The top two bits aren't connected and read high.
        return 0xC0 | selection | lines
    }

    private static func bit(for button: ConsoleButton) -> UInt8? {
        switch button {
        case .right: 0x01
        case .left: 0x02
        case .up: 0x04
        case .down: 0x08
        case .a: 0x10
        case .b: 0x20
        case .select: 0x40
        case .start: 0x80
        // The Game Boy has no shoulder buttons. The shell offers them because
        // another core will want them.
        case .l, .r: nil
        }
    }
}

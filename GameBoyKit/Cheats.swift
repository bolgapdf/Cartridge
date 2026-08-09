//
//  Cheats.swift
//  GameBoyKit
//

import Foundation

/// One address held at one value.
///
/// This is what the eight-digit cheat cartridge codes have always been: a byte,
/// an address, and the instruction to keep writing the first to the second. The
/// device sat between the cartridge and the console and rewrote memory once per
/// frame, which is why a frozen value flickers back rather than staying changed
/// — the game writes what it wants, and the cheat overwrites it a moment later.
public struct Cheat: Hashable, Sendable {
    public var address: UInt16
    /// Work RAM bank, for `$D000-$DFFF` on the Color. Ignored elsewhere.
    public var bank: Int
    public var value: UInt8
    public var isEnabled: Bool

    public init(address: UInt16, bank: Int = 0, value: UInt8, isEnabled: Bool = true) {
        self.address = address
        self.bank = bank
        self.value = value
        self.isEnabled = isEnabled
    }

    /// Parses `ttvvaaaa`, where the address is stored byte-swapped.
    ///
    /// Only type `01` is accepted. The other types did things this doesn't
    /// implement, and silently treating them as `01` would produce a cheat that
    /// looks like it was understood and writes to the wrong place.
    public init?(code: String, bank: Int = 0) {
        let cleaned = code.filter(\.isHexDigit)
        guard cleaned.count == 8, let raw = UInt32(cleaned, radix: 16) else { return nil }

        let type = UInt8((raw >> 24) & 0xFF)
        guard type == 0x01 else { return nil }

        let value = UInt8((raw >> 16) & 0xFF)
        let low = UInt16((raw >> 8) & 0xFF)
        let high = UInt16(raw & 0xFF)

        self.init(address: (high << 8) | low, bank: bank, value: value)
    }

    public var code: String {
        String(format: "01%02X%02X%02X", value, address & 0xFF, address >> 8)
    }
}

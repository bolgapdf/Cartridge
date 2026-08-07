//
//  Registers.swift
//  GameBoyKit
//

import Foundation

/// The four condition flags, stored in the top nibble of `F`.
public struct Flags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Result was zero.
    public static let zero = Flags(rawValue: 0x80)
    /// Last operation was a subtraction. Only `DAA` ever reads it.
    public static let subtract = Flags(rawValue: 0x40)
    /// Carry out of bit 3 — the nibble boundary, for BCD.
    public static let halfCarry = Flags(rawValue: 0x20)
    /// Carry out of bit 7 (or bit 15 for 16-bit adds).
    public static let carry = Flags(rawValue: 0x10)
}

/// The SM83 register file.
///
/// The eight-bit registers pair up into sixteen-bit ones, which the instruction
/// set uses constantly, so the pairs are computed rather than stored — there's
/// no separate state to keep in sync.
public struct Registers: Equatable, Sendable, Codable {
    public var a: UInt8 = 0
    public var b: UInt8 = 0
    public var c: UInt8 = 0
    public var d: UInt8 = 0
    public var e: UInt8 = 0
    public var h: UInt8 = 0
    public var l: UInt8 = 0

    /// The flags register.
    ///
    /// The low nibble is permanently zero on real hardware — writing 0xFF and
    /// reading back gives 0xF0. `POP AF` is the instruction that notices, and
    /// it's one of the first things the accuracy suites check.
    public var f: UInt8 = 0 {
        didSet { f &= 0xF0 }
    }

    public var sp: UInt16 = 0
    public var pc: UInt16 = 0

    public init() {}

    // MARK: - Pairs

    public var af: UInt16 {
        get { UInt16(a) << 8 | UInt16(f) }
        set { a = UInt8(newValue >> 8); f = UInt8(newValue & 0xFF) }
    }

    public var bc: UInt16 {
        get { UInt16(b) << 8 | UInt16(c) }
        set { b = UInt8(newValue >> 8); c = UInt8(newValue & 0xFF) }
    }

    public var de: UInt16 {
        get { UInt16(d) << 8 | UInt16(e) }
        set { d = UInt8(newValue >> 8); e = UInt8(newValue & 0xFF) }
    }

    public var hl: UInt16 {
        get { UInt16(h) << 8 | UInt16(l) }
        set { h = UInt8(newValue >> 8); l = UInt8(newValue & 0xFF) }
    }

    // MARK: - Flags

    public var flags: Flags {
        get { Flags(rawValue: f) }
        set { f = newValue.rawValue & 0xF0 }
    }

    public func has(_ flag: Flags) -> Bool {
        f & flag.rawValue != 0
    }

    public mutating func set(_ flag: Flags, _ on: Bool) {
        if on { f |= flag.rawValue } else { f &= ~flag.rawValue }
    }

    /// Sets all four flags at once, which is what most ALU operations want.
    public mutating func setFlags(zero: Bool, subtract: Bool, halfCarry: Bool, carry: Bool) {
        var value: UInt8 = 0
        if zero { value |= Flags.zero.rawValue }
        if subtract { value |= Flags.subtract.rawValue }
        if halfCarry { value |= Flags.halfCarry.rawValue }
        if carry { value |= Flags.carry.rawValue }
        f = value
    }

    /// State after the boot ROM hands over on a DMG.
    ///
    /// Starting here rather than executing the real boot ROM keeps a
    /// copyrighted 256-byte blob out of the project; the only thing lost is the
    /// scrolling Nintendo logo.
    public static var afterBoot: Registers {
        var registers = Registers()
        registers.af = 0x01B0
        registers.bc = 0x0013
        registers.de = 0x00D8
        registers.hl = 0x014D
        registers.sp = 0xFFFE
        registers.pc = 0x0100
        return registers
    }

    /// State after the Color's boot ROM hands over.
    ///
    /// The one that matters is A holding 0x11. Dual-mode cartridges read it on
    /// the first instruction to decide whether to set up colour palettes or
    /// stay monochrome, so getting it wrong doesn't produce wrong colours — it
    /// produces a game that never tries.
    public static var afterColorBoot: Registers {
        var registers = Registers()
        registers.af = 0x1180
        registers.bc = 0x0000
        registers.de = 0xFF56
        registers.hl = 0x000D
        registers.sp = 0xFFFE
        registers.pc = 0x0100
        return registers
    }
}

extension Registers: CustomStringConvertible {
    public var description: String {
        String(
            format: "AF:%04X BC:%04X DE:%04X HL:%04X SP:%04X PC:%04X",
            af, bc, de, hl, sp, pc
        )
    }
}

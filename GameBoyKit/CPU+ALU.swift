//
//  CPU+ALU.swift
//  GameBoyKit
//

import Foundation

/// Arithmetic, logic and bit operations, separated from decoding so the flag
/// rules — which are where emulators actually get things wrong — sit together
/// and can be read as a group.
extension CPU {

    // MARK: - 8-bit arithmetic

    func add(_ value: UInt8, carryIn: Bool = false) {
        let a = registers.a
        let carry: UInt8 = carryIn ? 1 : 0
        let result = Int(a) + Int(value) + Int(carry)

        registers.setFlags(
            zero: UInt8(truncatingIfNeeded: result) == 0,
            subtract: false,
            // Half-carry is a carry out of bit 3, so it's computed on the low
            // nibbles alone — including the incoming carry.
            halfCarry: (a & 0x0F) + (value & 0x0F) + carry > 0x0F,
            carry: result > 0xFF
        )
        registers.a = UInt8(truncatingIfNeeded: result)
    }

    func subtract(_ value: UInt8, carryIn: Bool = false, storeResult: Bool = true) {
        let a = registers.a
        let carry: UInt8 = carryIn ? 1 : 0
        let result = Int(a) - Int(value) - Int(carry)

        registers.setFlags(
            zero: UInt8(truncatingIfNeeded: result) == 0,
            subtract: true,
            halfCarry: Int(a & 0x0F) - Int(value & 0x0F) - Int(carry) < 0,
            carry: result < 0
        )
        // `CP` is a subtract that throws the result away and keeps the flags.
        if storeResult { registers.a = UInt8(truncatingIfNeeded: result) }
    }

    func and(_ value: UInt8) {
        registers.a &= value
        // The only logic operation that sets half-carry, for no obvious reason.
        registers.setFlags(zero: registers.a == 0, subtract: false, halfCarry: true, carry: false)
    }

    func or(_ value: UInt8) {
        registers.a |= value
        registers.setFlags(zero: registers.a == 0, subtract: false, halfCarry: false, carry: false)
    }

    func xor(_ value: UInt8) {
        registers.a ^= value
        registers.setFlags(zero: registers.a == 0, subtract: false, halfCarry: false, carry: false)
    }

    /// Increment leaves carry alone — that's what makes `INC` usable inside
    /// multi-byte addition loops.
    func increment(_ value: UInt8) -> UInt8 {
        let result = value &+ 1
        registers.set(.zero, result == 0)
        registers.set(.subtract, false)
        registers.set(.halfCarry, value & 0x0F == 0x0F)
        return result
    }

    func decrement(_ value: UInt8) -> UInt8 {
        let result = value &- 1
        registers.set(.zero, result == 0)
        registers.set(.subtract, true)
        registers.set(.halfCarry, value & 0x0F == 0x00)
        return result
    }

    // MARK: - 16-bit arithmetic

    /// `ADD HL,rr` leaves the zero flag untouched, which trips people up: it's
    /// the only add that doesn't set it.
    func addToHL(_ value: UInt16) {
        let hl = registers.hl
        let result = Int(hl) + Int(value)

        registers.set(.subtract, false)
        registers.set(.halfCarry, (hl & 0x0FFF) + (value & 0x0FFF) > 0x0FFF)
        registers.set(.carry, result > 0xFFFF)
        registers.hl = UInt16(truncatingIfNeeded: result)
    }

    /// Shared by `ADD SP,e8` and `LD HL,SP+e8`.
    ///
    /// The flags are the surprising part: despite being a sixteen-bit result,
    /// half-carry and carry are computed from the **low byte** of SP, as though
    /// it were an eight-bit addition. Zero is always cleared.
    func addSigned(_ base: UInt16, _ offset: Int8) -> UInt16 {
        let value = UInt16(bitPattern: Int16(offset))

        registers.setFlags(
            zero: false,
            subtract: false,
            halfCarry: (base & 0x0F) + (value & 0x0F) > 0x0F,
            carry: (base & 0xFF) + (value & 0xFF) > 0xFF
        )
        return base &+ value
    }

    // MARK: - Misc

    /// Decimal adjust after an addition or subtraction of BCD values.
    ///
    /// This is the one instruction that reads the subtract flag, which is the
    /// entire reason that flag exists: the correction has to be applied in the
    /// opposite direction after a subtraction.
    func decimalAdjust() {
        let subtracting = registers.has(.subtract)
        var correction: UInt8 = 0
        var carry = registers.has(.carry)

        // Both halves of the correction are decided from the value *before* any
        // of it is applied. Applying the low correction first and then testing
        // the adjusted value is a common shortcut and it is wrong: 0xFA needs
        // both corrections, but adding six first wraps it to 0x00, which no
        // longer looks like it needs the second.
        if registers.has(.halfCarry) || (!subtracting && registers.a & 0x0F > 0x09) {
            correction |= 0x06
        }
        if carry || (!subtracting && registers.a > 0x99) {
            correction |= 0x60
            // Carry means "the result needed more than two digits", and once
            // set it stays set — a subtraction never clears it.
            carry = true
        }

        registers.a = subtracting ? registers.a &- correction : registers.a &+ correction
        let a = registers.a
        registers.set(.zero, a == 0)
        registers.set(.halfCarry, false)
        registers.set(.carry, carry)
    }

    // MARK: - Rotates and shifts

    /// The `CB`-prefixed rotates set zero from the result. The four
    /// unprefixed ones (`RLCA`, `RRCA`, `RLA`, `RRA`) always clear it, even
    /// when the result is zero — a genuine asymmetry in the instruction set,
    /// not an oversight here.
    func rotateLeftCircular(_ value: UInt8, setsZero: Bool = true) -> UInt8 {
        let carry = value & 0x80 != 0
        let result = value << 1 | (carry ? 1 : 0)
        registers.setFlags(zero: setsZero && result == 0, subtract: false, halfCarry: false, carry: carry)
        return result
    }

    func rotateRightCircular(_ value: UInt8, setsZero: Bool = true) -> UInt8 {
        let carry = value & 0x01 != 0
        let result = value >> 1 | (carry ? 0x80 : 0)
        registers.setFlags(zero: setsZero && result == 0, subtract: false, halfCarry: false, carry: carry)
        return result
    }

    func rotateLeft(_ value: UInt8, setsZero: Bool = true) -> UInt8 {
        let carryIn: UInt8 = registers.has(.carry) ? 1 : 0
        let carryOut = value & 0x80 != 0
        let result = value << 1 | carryIn
        registers.setFlags(zero: setsZero && result == 0, subtract: false, halfCarry: false, carry: carryOut)
        return result
    }

    func rotateRight(_ value: UInt8, setsZero: Bool = true) -> UInt8 {
        let carryIn: UInt8 = registers.has(.carry) ? 0x80 : 0
        let carryOut = value & 0x01 != 0
        let result = value >> 1 | carryIn
        registers.setFlags(zero: setsZero && result == 0, subtract: false, halfCarry: false, carry: carryOut)
        return result
    }

    func shiftLeftArithmetic(_ value: UInt8) -> UInt8 {
        let carry = value & 0x80 != 0
        let result = value << 1
        registers.setFlags(zero: result == 0, subtract: false, halfCarry: false, carry: carry)
        return result
    }

    /// Arithmetic shift right keeps bit 7, preserving sign.
    func shiftRightArithmetic(_ value: UInt8) -> UInt8 {
        let carry = value & 0x01 != 0
        let result = value >> 1 | (value & 0x80)
        registers.setFlags(zero: result == 0, subtract: false, halfCarry: false, carry: carry)
        return result
    }

    func shiftRightLogical(_ value: UInt8) -> UInt8 {
        let carry = value & 0x01 != 0
        let result = value >> 1
        registers.setFlags(zero: result == 0, subtract: false, halfCarry: false, carry: carry)
        return result
    }

    func swapNibbles(_ value: UInt8) -> UInt8 {
        let result = value << 4 | value >> 4
        registers.setFlags(zero: result == 0, subtract: false, halfCarry: false, carry: false)
        return result
    }

    // MARK: - Bit operations

    /// `BIT` leaves carry alone — it's a test, not an operation.
    func testBit(_ bit: UInt8, of value: UInt8) {
        registers.set(.zero, value & (1 << bit) == 0)
        registers.set(.subtract, false)
        registers.set(.halfCarry, true)
    }
}

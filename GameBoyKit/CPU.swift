//
//  CPU.swift
//  GameBoyKit
//

import Foundation

/// Anything the CPU can read and write.
///
/// The CPU deliberately knows nothing about cartridges, video memory or
/// hardware registers — it only knows how to ask the bus. That's what lets the
/// whole instruction set be verified against a flat 64 KB array with no rest of
/// the console attached.
public protocol Bus: AnyObject {
    func read(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
}

/// The five interrupt sources.
///
/// Their bit order in `IF` and `IE` is also their priority order, and also the
/// order of their handler addresses from 0x40 upward in eight-byte steps — which
/// is why dispatch can be arithmetic rather than a table.
public enum Interrupt: UInt8, CaseIterable, Sendable {
    case vblank = 0x01
    case lcdStatus = 0x02
    case timer = 0x04
    case serial = 0x08
    case joypad = 0x10
}

/// The Sharp SM83 — the Game Boy's processor.
///
/// Often called "a Z80" and it isn't; it's closer to an 8080 with a handful of
/// Z80 instructions, its own `LDH`/`LD (HL±),A` additions, and none of the Z80's
/// index registers, alternate register set or block instructions.
///
/// Timing is counted in **M-cycles** (one machine cycle, four clocks). Every
/// memory access is exactly one M-cycle, which is what makes the cycle counts
/// come out right almost for free.
public final class CPU: Codable {
    public var registers: Registers

    /// Interrupt master enable.
    public var ime = false
    /// `EI` enables interrupts *after the following instruction*, so the effect
    /// is deferred by one step. Games rely on this to `EI`/`RET` atomically.
    public var imeScheduled = false
    public var halted = false
    /// Set when `HALT` executes with interrupts disabled and one already
    /// pending. On real hardware the program counter fails to increment for one
    /// instruction, so the next byte runs twice.
    public var haltBug = false

    /// Interrupt enable and flag registers live in the bus, but the CPU needs
    /// them to decide whether to wake and dispatch.
    public var interruptEnable: UInt8 = 0
    public var interruptFlags: UInt8 = 0

    public init(registers: Registers = .afterBoot) {
        self.registers = registers
    }

    /// Flags an interrupt as pending. Whether it's taken is up to `IE` and the
    /// master enable; a source that isn't enabled still sets its flag, and the
    /// flag still wakes the CPU from `HALT`.
    @inline(__always)
    public func request(_ interrupt: Interrupt) {
        interruptFlags |= interrupt.rawValue
    }

    // MARK: - Stepping

    /// Executes one instruction, or services an interrupt, and returns the
    /// number of M-cycles it took.
    @discardableResult
    public func step(_ bus: Bus) -> Int {
        if let cycles = serviceInterrupt(bus) { return cycles }

        if halted { return 1 }

        // `EI` takes effect after the next instruction has been fetched, so the
        // pending enable is applied before executing, not after.
        let enabling = imeScheduled
        imeScheduled = false

        let opcode = fetch(bus)
        if haltBug {
            // The halt bug: PC didn't advance, so this byte gets read again.
            registers.pc &-= 1
            haltBug = false
        }

        let cycles = execute(opcode, bus)
        if enabling { ime = true }
        return cycles
    }

    /// Dispatches the highest-priority pending interrupt, if any.
    private func serviceInterrupt(_ bus: Bus) -> Int? {
        let pending = interruptEnable & interruptFlags & 0x1F
        guard pending != 0 else { return nil }

        // A pending interrupt wakes the CPU even when IME is clear; that's the
        // difference between HALT and STOP.
        halted = false
        guard ime else { return nil }

        let bit = pending.trailingZeroBitCount
        ime = false
        interruptFlags &= ~(UInt8(1) << UInt8(bit))

        push(registers.pc, bus)
        registers.pc = UInt16(0x40 + bit * 8)
        return 5
    }

    // MARK: - Memory helpers

    @inline(__always)
    func fetch(_ bus: Bus) -> UInt8 {
        let byte = bus.read(registers.pc)
        registers.pc &+= 1
        return byte
    }

    @inline(__always)
    func fetchWord(_ bus: Bus) -> UInt16 {
        let low = UInt16(fetch(bus))
        let high = UInt16(fetch(bus))
        return high << 8 | low
    }

    @inline(__always)
    func push(_ value: UInt16, _ bus: Bus) {
        registers.sp &-= 1
        bus.write(registers.sp, UInt8(value >> 8))
        registers.sp &-= 1
        bus.write(registers.sp, UInt8(value & 0xFF))
    }

    @inline(__always)
    func pop(_ bus: Bus) -> UInt16 {
        let low = UInt16(bus.read(registers.sp))
        registers.sp &+= 1
        let high = UInt16(bus.read(registers.sp))
        registers.sp &+= 1
        return high << 8 | low
    }

    // MARK: - Register file addressing

    /// The order the opcode map uses for its three-bit register field:
    /// B, C, D, E, H, L, (HL), A. Index 6 is memory, not a register, which is
    /// why so many instructions cost one extra cycle in that slot.
    @inline(__always)
    func register(_ index: UInt8, _ bus: Bus) -> UInt8 {
        switch index {
        case 0: registers.b
        case 1: registers.c
        case 2: registers.d
        case 3: registers.e
        case 4: registers.h
        case 5: registers.l
        case 6: bus.read(registers.hl)
        default: registers.a
        }
    }

    @inline(__always)
    func setRegister(_ index: UInt8, _ value: UInt8, _ bus: Bus) {
        switch index {
        case 0: registers.b = value
        case 1: registers.c = value
        case 2: registers.d = value
        case 3: registers.e = value
        case 4: registers.h = value
        case 5: registers.l = value
        case 6: bus.write(registers.hl, value)
        default: registers.a = value
        }
    }

    /// True when the register field refers to `(HL)` and therefore costs a
    /// memory access.
    @inline(__always)
    func isMemory(_ index: UInt8) -> Bool { index == 6 }

    /// The two-bit condition field: NZ, Z, NC, C.
    @inline(__always)
    func condition(_ index: UInt8) -> Bool {
        switch index {
        case 0: !registers.has(.zero)
        case 1: registers.has(.zero)
        case 2: !registers.has(.carry)
        default: registers.has(.carry)
        }
    }
}

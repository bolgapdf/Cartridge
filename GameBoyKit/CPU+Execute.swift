//
//  CPU+Execute.swift
//  GameBoyKit
//

import Foundation

/// Instruction decoding.
///
/// The opcode map is decoded structurally rather than as ~500 individual cases,
/// because it is genuinely structured: an opcode splits into `xxyyyzzz`, where
/// `x` picks a block, `y` and `z` select registers, conditions or operations.
/// Whole regions — every `LD r,r'`, every ALU op, the entire `CB` page — fall
/// out of that as a handful of lines each.
///
/// Returned values are **M-cycles**. Anything touching `(HL)` costs an extra
/// one for the memory access, which the decode accounts for by checking the
/// register index rather than by listing cycle counts per opcode.
extension CPU {

    func execute(_ opcode: UInt8, _ bus: Bus) -> Int {
        let x = opcode >> 6
        let y = (opcode >> 3) & 0x07
        let z = opcode & 0x07
        let p = y >> 1
        let q = y & 0x01

        switch x {
        case 0: return executeBlock0(opcode, y: y, z: z, p: p, q: q, bus)
        case 1: return executeLoad(y: y, z: z, bus)
        case 2: return executeALU(operation: y, operand: z, bus)
        default: return executeBlock3(opcode, y: y, z: z, p: p, q: q, bus)
        }
    }

    // MARK: - 0x00–0x3F

    private func executeBlock0(
        _ opcode: UInt8, y: UInt8, z: UInt8, p: UInt8, q: UInt8, _ bus: Bus
    ) -> Int {
        switch z {
        case 0:
            switch y {
            case 0:
                return 1                                    // NOP
            case 1:                                         // LD (a16),SP
                let address = fetchWord(bus)
                bus.write(address, UInt8(registers.sp & 0xFF))
                bus.write(address &+ 1, UInt8(registers.sp >> 8))
                return 5
            case 2:                                         // STOP
                // Usually documented as a two-byte instruction, but the
                // reference advances PC by one and lets the following 0x00
                // execute as a NOP — same net effect, and it matches what the
                // hardware actually does.
                return 3
            case 3:                                         // JR e8
                let offset = Int8(bitPattern: fetch(bus))
                registers.pc = registers.pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            default:                                        // JR cc,e8
                let offset = Int8(bitPattern: fetch(bus))
                guard condition(y - 4) else { return 2 }
                registers.pc = registers.pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }

        case 1:
            if q == 0 {                                     // LD rr,d16
                setPair(p, fetchWord(bus))
                return 3
            } else {                                        // ADD HL,rr
                addToHL(pair(p))
                return 2
            }

        case 2:
            // The (HL+) and (HL-) forms are the SM83's own addition, and are
            // why so much Game Boy code copies memory without a loop counter.
            let address: UInt16
            switch p {
            case 0: address = registers.bc
            case 1: address = registers.de
            case 2: address = registers.hl; registers.hl = registers.hl &+ 1
            default: address = registers.hl; registers.hl = registers.hl &- 1
            }
            if q == 0 {
                bus.write(address, registers.a)
            } else {
                registers.a = bus.read(address)
            }
            return 2

        case 3:                                             // INC/DEC rr
            setPair(p, q == 0 ? pair(p) &+ 1 : pair(p) &- 1)
            return 2

        case 4:                                             // INC r
            setRegister(y, increment(register(y, bus)), bus)
            return isMemory(y) ? 3 : 1

        case 5:                                             // DEC r
            setRegister(y, decrement(register(y, bus)), bus)
            return isMemory(y) ? 3 : 1

        case 6:                                             // LD r,d8
            let value = fetch(bus)
            setRegister(y, value, bus)
            return isMemory(y) ? 3 : 2

        default:
            switch y {
            case 0: registers.a = rotateLeftCircular(registers.a, setsZero: false)   // RLCA
            case 1: registers.a = rotateRightCircular(registers.a, setsZero: false)  // RRCA
            case 2: registers.a = rotateLeft(registers.a, setsZero: false)           // RLA
            case 3: registers.a = rotateRight(registers.a, setsZero: false)          // RRA
            case 4: decimalAdjust()                                                  // DAA
            case 5:                                                                  // CPL
                registers.a = ~registers.a
                registers.set(.subtract, true)
                registers.set(.halfCarry, true)
            case 6:                                                                  // SCF
                registers.set(.subtract, false)
                registers.set(.halfCarry, false)
                registers.set(.carry, true)
            default:                                                                 // CCF
                registers.set(.subtract, false)
                registers.set(.halfCarry, false)
                registers.set(.carry, !registers.has(.carry))
            }
            return 1
        }
    }

    // MARK: - 0x40–0x7F

    private func executeLoad(y: UInt8, z: UInt8, _ bus: Bus) -> Int {
        // 0x76 would be `LD (HL),(HL)`, which is meaningless, so the slot is
        // reused for HALT.
        if y == 6 && z == 6 {
            return executeHalt()
        }
        setRegister(y, register(z, bus), bus)
        return (isMemory(y) || isMemory(z)) ? 2 : 1
    }

    private func executeHalt() -> Int {
        let pending = interruptEnable & interruptFlags & 0x1F
        if !ime && pending != 0 {
            // The halt bug. Rather than halting, the CPU carries on with a
            // program counter that fails to increment once, so the next byte
            // executes twice. Real games depend on this.
            haltBug = true
        } else {
            halted = true
        }
        // One fetch plus two idle cycles. The reference records those idle
        // cycles explicitly (as entries with no bus access), and the same is
        // true of STOP. If this turns out to be an artefact of how the
        // reference harness stops, Mooneye's timing tests will say so.
        return 3
    }

    // MARK: - 0x80–0xBF

    private func executeALU(operation: UInt8, operand: UInt8, _ bus: Bus) -> Int {
        apply(operation: operation, to: register(operand, bus))
        return isMemory(operand) ? 2 : 1
    }

    private func apply(operation: UInt8, to value: UInt8) {
        switch operation {
        case 0: add(value)
        case 1: add(value, carryIn: registers.has(.carry))
        case 2: subtract(value)
        case 3: subtract(value, carryIn: registers.has(.carry))
        case 4: and(value)
        case 5: xor(value)
        case 6: or(value)
        default: subtract(value, storeResult: false)          // CP
        }
    }

    // MARK: - 0xC0–0xFF

    private func executeBlock3(
        _ opcode: UInt8, y: UInt8, z: UInt8, p: UInt8, q: UInt8, _ bus: Bus
    ) -> Int {
        switch z {
        case 0:
            switch y {
            case 0...3:                                     // RET cc
                guard condition(y) else { return 2 }
                registers.pc = pop(bus)
                return 5
            case 4:                                          // LDH (a8),A
                bus.write(0xFF00 | UInt16(fetch(bus)), registers.a)
                return 3
            case 5:                                          // ADD SP,e8
                registers.sp = addSigned(registers.sp, Int8(bitPattern: fetch(bus)))
                return 4
            case 6:                                          // LDH A,(a8)
                registers.a = bus.read(0xFF00 | UInt16(fetch(bus)))
                return 3
            default:                                         // LD HL,SP+e8
                registers.hl = addSigned(registers.sp, Int8(bitPattern: fetch(bus)))
                return 3
            }

        case 1:
            if q == 0 {                                      // POP rr
                let value = pop(bus)
                // The low nibble of F is hardwired to zero, so `POP AF` can't
                // restore it. `Registers.f` enforces that on every write.
                setStackPair(p, value)
                return 3
            }
            switch p {
            case 0:                                          // RET
                registers.pc = pop(bus)
                return 4
            case 1:                                          // RETI
                registers.pc = pop(bus)
                ime = true
                return 4
            case 2:                                          // JP HL
                registers.pc = registers.hl
                return 1
            default:                                         // LD SP,HL
                registers.sp = registers.hl
                return 2
            }

        case 2:
            switch y {
            case 0...3:                                      // JP cc,a16
                let address = fetchWord(bus)
                guard condition(y) else { return 3 }
                registers.pc = address
                return 4
            case 4:                                          // LD (C),A
                bus.write(0xFF00 | UInt16(registers.c), registers.a)
                return 2
            case 5:                                          // LD (a16),A
                bus.write(fetchWord(bus), registers.a)
                return 4
            case 6:                                          // LD A,(C)
                registers.a = bus.read(0xFF00 | UInt16(registers.c))
                return 2
            default:                                         // LD A,(a16)
                registers.a = bus.read(fetchWord(bus))
                return 4
            }

        case 3:
            switch y {
            case 0:                                          // JP a16
                registers.pc = fetchWord(bus)
                return 4
            case 1:
                return executeCB(fetch(bus), bus)
            case 6:                                          // DI
                ime = false
                imeScheduled = false
                return 1
            case 7:                                          // EI
                imeScheduled = true
                return 1
            default:
                // 0xD3, 0xDB, 0xDD, 0xE3, 0xE4 and friends don't exist. Real
                // hardware locks up; treating them as a no-op keeps a bad ROM
                // from taking the whole app down.
                return 1
            }

        case 4:                                              // CALL cc,a16
            guard y <= 3 else { return 1 }
            let address = fetchWord(bus)
            guard condition(y) else { return 3 }
            push(registers.pc, bus)
            registers.pc = address
            return 6

        case 5:
            if q == 0 {                                      // PUSH rr
                push(stackPair(p), bus)
                return 4
            }
            guard p == 0 else { return 1 }                   // CALL a16
            let address = fetchWord(bus)
            push(registers.pc, bus)
            registers.pc = address
            return 6

        case 6:                                              // ALU A,d8
            apply(operation: y, to: fetch(bus))
            return 2

        default:                                             // RST
            push(registers.pc, bus)
            registers.pc = UInt16(y) * 8
            return 4
        }
    }

    // MARK: - 0xCB page

    /// Entirely regular: the top two bits pick rotate/shift, `BIT`, `RES` or
    /// `SET`, and the remaining bits are a bit index and a register.
    private func executeCB(_ opcode: UInt8, _ bus: Bus) -> Int {
        let x = opcode >> 6
        let y = (opcode >> 3) & 0x07
        let z = opcode & 0x07
        let value = register(z, bus)

        switch x {
        case 0:
            let result: UInt8
            switch y {
            case 0: result = rotateLeftCircular(value)
            case 1: result = rotateRightCircular(value)
            case 2: result = rotateLeft(value)
            case 3: result = rotateRight(value)
            case 4: result = shiftLeftArithmetic(value)
            case 5: result = shiftRightArithmetic(value)
            case 6: result = swapNibbles(value)
            default: result = shiftRightLogical(value)
            }
            setRegister(z, result, bus)
            return isMemory(z) ? 4 : 2

        case 1:                                              // BIT — read only
            testBit(y, of: value)
            return isMemory(z) ? 3 : 2

        case 2:                                              // RES
            setRegister(z, value & ~(1 << y), bus)
            return isMemory(z) ? 4 : 2

        default:                                             // SET
            setRegister(z, value | (1 << y), bus)
            return isMemory(z) ? 4 : 2
        }
    }

    // MARK: - Register pair addressing

    /// BC, DE, HL, SP — used by most sixteen-bit instructions.
    @inline(__always)
    private func pair(_ index: UInt8) -> UInt16 {
        switch index {
        case 0: registers.bc
        case 1: registers.de
        case 2: registers.hl
        default: registers.sp
        }
    }

    @inline(__always)
    private func setPair(_ index: UInt8, _ value: UInt16) {
        switch index {
        case 0: registers.bc = value
        case 1: registers.de = value
        case 2: registers.hl = value
        default: registers.sp = value
        }
    }

    /// BC, DE, HL, AF — `PUSH` and `POP` use AF where the others use SP.
    @inline(__always)
    private func stackPair(_ index: UInt8) -> UInt16 {
        switch index {
        case 0: registers.bc
        case 1: registers.de
        case 2: registers.hl
        default: registers.af
        }
    }

    @inline(__always)
    private func setStackPair(_ index: UInt8, _ value: UInt16) {
        switch index {
        case 0: registers.bc = value
        case 1: registers.de = value
        case 2: registers.hl = value
        default: registers.af = value
        }
    }
}

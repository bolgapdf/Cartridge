//
//  Mappers.swift
//  GameBoyKit
//

import Foundation

/// The Game Boy can only address 32 KB of cartridge at once, and almost every
/// game is larger than that. A memory bank controller sits on the cartridge and
/// swaps chunks of ROM in and out of the upper 16 KB in response to writes.
///
/// Those writes go to ROM addresses, which is the trick: the chip watches the
/// address bus, so a `LD (0x2000),A` that appears to write to read-only memory
/// is really the game asking for a different bank.
protocol Mapper: AnyObject {
    /// 0x0000–0x7FFF.
    func readROM(_ address: UInt16) -> UInt8
    /// 0xA000–0xBFFF.
    func readRAM(_ address: UInt16) -> UInt8
    func writeRAM(_ address: UInt16, _ value: UInt8)
    /// A write into ROM space — a command to the chip, not stored data.
    func writeControl(_ address: UInt16, _ value: UInt8)

    var ram: [UInt8] { get set }
    var state: MapperState { get set }
}

/// Everything a mapper needs restored from a save state.
///
/// One struct covering all of them rather than one per chip: the fields are
/// nearly identical, and a save state that names its mapper would break the
/// moment a game was reloaded through a different one.
struct MapperState: Codable {
    var romBank = 1
    var ramBank = 0
    var ramEnabled = false
    var mode = 0
    /// `Data` for the same reason the console's RAM is: a binary plist stores
    /// bytes as bytes.
    var ram = Data()
    /// MBC3 only: seconds of clock time, and whether the clock is stopped.
    var clockElapsed: Double = 0
    var clockHalted = false
    var latchedClock: [UInt8] = []
}

/// Shared plumbing: a ROM padded to its full bank count so that indexing is
/// unconditional, and RAM sized once up front.
class BaseMapper {
    /// Padded to `banks * 16 KB`. A truncated or over-long file would otherwise
    /// need a bounds check on every single memory read.
    let rom: [UInt8]
    let bankMask: Int
    var ram: [UInt8]
    var ramEnabled = false

    init(rom: [UInt8], banks: Int, ramBytes: Int) {
        let capacity = banks * 0x4000
        var padded = rom
        if padded.count < capacity {
            padded.append(contentsOf: [UInt8](repeating: 0xFF, count: capacity - padded.count))
        } else if padded.count > capacity {
            padded.removeLast(padded.count - capacity)
        }
        self.rom = padded
        self.bankMask = banks - 1
        self.ram = [UInt8](repeating: 0, count: ramBytes)
    }

    @inline(__always)
    final func romByte(bank: Int, offset: UInt16) -> UInt8 {
        // Bank numbers wrap rather than fault: the chip only has as many
        // address lines as the ROM needs, so the high bits are simply not
        // connected to anything.
        rom[(bank & bankMask) * 0x4000 + Int(offset & 0x3FFF)]
    }

    /// Disabled RAM reads as 0xFF — the bus floats high when nothing drives it.
    @inline(__always)
    final func ramByte(at index: Int) -> UInt8 {
        guard ramEnabled, !ram.isEmpty else { return 0xFF }
        return ram[index % ram.count]
    }

    @inline(__always)
    final func setRAMByte(at index: Int, _ value: UInt8) {
        guard ramEnabled, !ram.isEmpty else { return }
        ram[index % ram.count] = value
    }
}

// MARK: - No mapper

/// 32 KB of ROM wired straight to the bus. Tetris, Dr. Mario, and most of the
/// launch window.
final class NoMapper: BaseMapper, Mapper {
    init(rom: [UInt8], ramBytes: Int) {
        super.init(rom: rom, banks: 2, ramBytes: ramBytes)
    }

    func readROM(_ address: UInt16) -> UInt8 { rom[Int(address) & 0x7FFF] }
    func readRAM(_ address: UInt16) -> UInt8 { ramByte(at: Int(address & 0x1FFF)) }
    func writeRAM(_ address: UInt16, _ value: UInt8) { setRAMByte(at: Int(address & 0x1FFF), value) }

    /// There's no chip to talk to, so the write goes nowhere. Some games do it
    /// anyway through shared code paths.
    func writeControl(_ address: UInt16, _ value: UInt8) {
        if address < 0x2000 { ramEnabled = value & 0x0F == 0x0A }
    }

    var state: MapperState {
        get { MapperState(ram: Data(ram)) }
        set { if newValue.ram.count == ram.count { ram = [UInt8](newValue.ram) } }
    }
}

// MARK: - MBC1

/// The first and most common mapper: up to 2 MB of ROM and 32 KB of RAM.
///
/// Its two bank registers are five bits and two bits, and how they combine
/// depends on a mode flag — which is the part everyone gets wrong. In mode 1 the
/// *lower* 16 KB stops being fixed at bank 0, which is how the few 1 MB+ games
/// reach their upper half.
final class MBC1: BaseMapper, Mapper {
    private var bank1 = 1          // low five bits
    private var bank2 = 0          // high two bits, or the RAM bank
    private var advancedMode = false

    func readROM(_ address: UInt16) -> UInt8 {
        if address < 0x4000 {
            return romByte(bank: advancedMode ? bank2 << 5 : 0, offset: address)
        }
        return romByte(bank: bank2 << 5 | bank1, offset: address)
    }

    func readRAM(_ address: UInt16) -> UInt8 {
        ramByte(at: ramOffset(address))
    }

    func writeRAM(_ address: UInt16, _ value: UInt8) {
        setRAMByte(at: ramOffset(address), value)
    }

    func writeControl(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0x0000...0x1FFF:
            ramEnabled = value & 0x0F == 0x0A
        case 0x2000...0x3FFF:
            // Bank 0 is unreachable here: the chip forces it to 1, which is why
            // banks 0x20, 0x40 and 0x60 are also unreachable on large ROMs and
            // why cartridges leave those banks empty.
            bank1 = Int(value & 0x1F)
            if bank1 == 0 { bank1 = 1 }
        case 0x4000...0x5FFF:
            bank2 = Int(value & 0x03)
        default:
            advancedMode = value & 0x01 == 1
        }
    }

    private func ramOffset(_ address: UInt16) -> Int {
        // RAM banking only happens in advanced mode; otherwise every game sees
        // bank 0 no matter what bank2 holds.
        let bank = advancedMode ? bank2 : 0
        return bank * 0x2000 + Int(address & 0x1FFF)
    }

    var state: MapperState {
        get {
            MapperState(
                romBank: bank1, ramBank: bank2, ramEnabled: ramEnabled,
                mode: advancedMode ? 1 : 0, ram: Data(ram)
            )
        }
        set {
            bank1 = newValue.romBank
            bank2 = newValue.ramBank
            ramEnabled = newValue.ramEnabled
            advancedMode = newValue.mode == 1
            if newValue.ram.count == ram.count { ram = [UInt8](newValue.ram) }
        }
    }
}

// MARK: - MBC2

/// Small and strange: 256 KB of ROM maximum, and 512 *nibbles* of RAM built
/// into the mapper itself rather than a separate chip.
///
/// Which of its two registers a write targets is chosen by bit 8 of the
/// address, not by the address range, so 0x2100 and 0x2000 do entirely
/// different things.
final class MBC2: BaseMapper, Mapper {
    private var romBank = 1

    init(rom: [UInt8], banks: Int) {
        super.init(rom: rom, banks: banks, ramBytes: 512)
    }

    func readROM(_ address: UInt16) -> UInt8 {
        address < 0x4000 ? romByte(bank: 0, offset: address)
                         : romByte(bank: romBank, offset: address)
    }

    /// Only the low nibble is real. The upper four bits aren't connected, and
    /// hardware reads them back as 1s.
    func readRAM(_ address: UInt16) -> UInt8 {
        ramByte(at: Int(address & 0x01FF)) | 0xF0
    }

    func writeRAM(_ address: UInt16, _ value: UInt8) {
        setRAMByte(at: Int(address & 0x01FF), value & 0x0F)
    }

    func writeControl(_ address: UInt16, _ value: UInt8) {
        guard address < 0x4000 else { return }
        if address & 0x0100 == 0 {
            ramEnabled = value & 0x0F == 0x0A
        } else {
            romBank = max(Int(value & 0x0F), 1)
        }
    }

    var state: MapperState {
        get { MapperState(romBank: romBank, ramEnabled: ramEnabled, ram: Data(ram)) }
        set {
            romBank = newValue.romBank
            ramEnabled = newValue.ramEnabled
            if newValue.ram.count == ram.count { ram = [UInt8](newValue.ram) }
        }
    }
}

// MARK: - MBC3

/// MBC1 without the mode-register awkwardness, plus a real-time clock — the one
/// Pokémon Gold and Silver use to know it's night.
///
/// The clock is modelled as an offset from wall-clock time rather than as a
/// counter ticked by the emulator. That keeps time passing while the app is
/// closed, which is exactly what the battery-backed original did.
final class MBC3: BaseMapper, Mapper {
    private var romBank = 1
    /// 0x00–0x03 selects RAM; 0x08–0x0C selects a clock register.
    private var bankSelect = 0
    private var clockStart = Date().timeIntervalSince1970
    private var stoppedElapsed: Double = 0
    private var clockStopped = false
    private var latched = [UInt8](repeating: 0, count: 5)
    private var lastLatchWrite: UInt8 = 0xFF

    func readROM(_ address: UInt16) -> UInt8 {
        address < 0x4000 ? romByte(bank: 0, offset: address)
                         : romByte(bank: romBank, offset: address)
    }

    func readRAM(_ address: UInt16) -> UInt8 {
        if bankSelect >= 0x08 && bankSelect <= 0x0C {
            return ramEnabled ? latched[bankSelect - 0x08] : 0xFF
        }
        return ramByte(at: bankSelect * 0x2000 + Int(address & 0x1FFF))
    }

    func writeRAM(_ address: UInt16, _ value: UInt8) {
        if bankSelect >= 0x08 && bankSelect <= 0x0C {
            guard ramEnabled else { return }
            writeClock(register: bankSelect - 0x08, value)
            return
        }
        setRAMByte(at: bankSelect * 0x2000 + Int(address & 0x1FFF), value)
    }

    func writeControl(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0x0000...0x1FFF:
            ramEnabled = value & 0x0F == 0x0A
        case 0x2000...0x3FFF:
            // Seven bits here rather than MBC1's five, so no banks go missing.
            romBank = max(Int(value & 0x7F), 1)
        case 0x4000...0x5FFF:
            bankSelect = Int(value)
        default:
            // Writing 0 then 1 freezes the current time into the readable
            // registers, so a game reading five bytes can't be caught by a
            // rollover partway through.
            if lastLatchWrite == 0 && value == 1 { latchClock() }
            lastLatchWrite = value
        }
    }

    // MARK: Clock

    private var elapsed: Double {
        clockStopped ? stoppedElapsed : Date().timeIntervalSince1970 - clockStart
    }

    private func latchClock() {
        let total = Int(max(elapsed, 0))
        let days = total / 86_400
        latched[0] = UInt8(total % 60)
        latched[1] = UInt8((total / 60) % 60)
        latched[2] = UInt8((total / 3600) % 24)
        latched[3] = UInt8(days & 0xFF)
        // Bit 0 is the ninth day bit, bit 6 stops the clock, and bit 7 latches
        // high forever once the counter passes 511 days.
        var high: UInt8 = UInt8((days >> 8) & 0x01)
        if clockStopped { high |= 0x40 }
        if days > 511 { high |= 0x80 }
        latched[4] = high
    }

    private func writeClock(register: Int, _ value: UInt8) {
        latchClock()
        latched[register] = value

        if register == 4 {
            let shouldStop = value & 0x40 != 0
            if shouldStop && !clockStopped { stoppedElapsed = elapsed }
            clockStopped = shouldStop
        }

        // Rebuild the offset so that "now" reads back as whatever was just
        // written. Setting the clock is rare enough that recomputing beats
        // keeping a second representation in sync.
        let days = Int(latched[3]) | (Int(latched[4] & 0x01) << 8)
        let total = Double(
            Int(latched[0]) + Int(latched[1]) * 60 + Int(latched[2]) * 3600 + days * 86_400
        )
        if clockStopped {
            stoppedElapsed = total
        } else {
            clockStart = Date().timeIntervalSince1970 - total
        }
    }

    var state: MapperState {
        get {
            MapperState(
                romBank: romBank, ramBank: bankSelect, ramEnabled: ramEnabled,
                ram: Data(ram), clockElapsed: elapsed, clockHalted: clockStopped,
                latchedClock: latched
            )
        }
        set {
            romBank = newValue.romBank
            bankSelect = newValue.ramBank
            ramEnabled = newValue.ramEnabled
            if newValue.ram.count == ram.count { ram = [UInt8](newValue.ram) }
            clockStopped = newValue.clockHalted
            stoppedElapsed = newValue.clockElapsed
            clockStart = Date().timeIntervalSince1970 - newValue.clockElapsed
            if newValue.latchedClock.count == 5 { latched = newValue.latchedClock }
        }
    }
}

// MARK: - MBC5

/// The last of the line: 8 MB of ROM, 128 KB of RAM, and a nine-bit bank
/// register split across two addresses so that bank 0 is finally selectable in
/// the upper region.
final class MBC5: BaseMapper, Mapper {
    private var romBank = 1
    private var ramBank = 0

    func readROM(_ address: UInt16) -> UInt8 {
        address < 0x4000 ? romByte(bank: 0, offset: address)
                         : romByte(bank: romBank, offset: address)
    }

    func readRAM(_ address: UInt16) -> UInt8 {
        ramByte(at: ramBank * 0x2000 + Int(address & 0x1FFF))
    }

    func writeRAM(_ address: UInt16, _ value: UInt8) {
        setRAMByte(at: ramBank * 0x2000 + Int(address & 0x1FFF), value)
    }

    func writeControl(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0x0000...0x1FFF:
            ramEnabled = value & 0x0F == 0x0A
        case 0x2000...0x2FFF:
            romBank = (romBank & 0x100) | Int(value)
        case 0x3000...0x3FFF:
            romBank = (romBank & 0xFF) | (Int(value & 0x01) << 8)
        case 0x4000...0x5FFF:
            ramBank = Int(value & 0x0F)
        default:
            break
        }
    }

    var state: MapperState {
        get { MapperState(romBank: romBank, ramBank: ramBank, ramEnabled: ramEnabled, ram: Data(ram)) }
        set {
            romBank = newValue.romBank
            ramBank = newValue.ramBank
            ramEnabled = newValue.ramEnabled
            if newValue.ram.count == ram.count { ram = [UInt8](newValue.ram) }
        }
    }
}

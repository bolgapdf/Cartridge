//
//  GameBoy.swift
//  GameBoyKit
//

import Foundation

/// The console: the memory map, the wiring between the chips, and the frame
/// loop.
///
/// This is also the `Bus` the CPU talks to. Address decoding on real hardware is
/// a handful of logic gates comparing the top few address bits, and the switch
/// below is a direct transcription of that — which is why the ranges look
/// arbitrary but never overlap.
public final class GameBoy: EmulatedSystem, Bus {

    public static let name = "Game Boy"
    public static let fileExtensions = ["gb", "gbc"]
    public static let screenSize = ScreenSize(width: PPU.width, height: PPU.height)
    /// Not 60. The clock divides to 59.7275 Hz, and treating it as 60 makes
    /// audio drift about a sample every two seconds — audible as a tick.
    public static let frameRate = 4_194_304.0 / Double(PPU.clocksPerFrame)
    public static let sampleRate = 48_000.0

    var cpu = CPU()
    var ppu = PPU()
    var timer = SystemTimer()
    var joypad = Joypad()
    var apu = APU()
    private var cartridge: GameCartridge?

    /// The name in the cartridge header, or nil with no cartridge inserted.
    public var cartridgeTitle: String? { cartridge?.header.title }

    /// Eight 4 KB banks on the Color, of which a DMG only ever sees the first
    /// two. The low half is always bank 0; the high half is switchable.
    private var workRAM = [UInt8](repeating: 0, count: 0x8000)
    private var workRAMBank = 1

    /// True when a Color cartridge is running with the Color hardware awake.
    public private(set) var colorMode = false

    /// The Color can run its CPU at twice the clock. The video and sound
    /// hardware do not follow — which is the entire point, since the extra
    /// speed exists to give games more time between scanlines.
    private var doubleSpeed = false
    private var speedSwitchArmed = false

    /// Source, destination and remaining length of a VRAM transfer.
    private var hdmaSource: UInt16 = 0
    private var hdmaDestination: UInt16 = 0
    private var hdmaRemaining = 0
    private var hdmaActive = false
    private var highRAM = [UInt8](repeating: 0, count: 0x7F)
    /// Registers this core doesn't model. Storing the writes lets a game read
    /// back what it wrote, which is all most of them check for.
    private var unmappedIO = [UInt8](repeating: 0, count: 0x80)

    private var serialData: UInt8 = 0
    private var serialControl: UInt8 = 0

    /// Everything written to the serial port since the last read.
    ///
    /// Nothing is plugged into the link cable, so on hardware this goes nowhere.
    /// The test ROMs use it as a console, which makes them runnable with no
    /// screen attached at all.
    public private(set) var serialOutput = ""

    /// Leftover clocks from the previous frame. Instructions don't divide evenly
    /// into a frame, so the remainder carries rather than being rounded away.
    private var carriedCycles = 0
    /// Clocks already charged by bus accesses during the current instruction.
    private var accessCycles = 0
    /// Set while DMA is copying, so its 160 reads don't each advance the clock
    /// a second time.
    private var suppressTiming = false

    public init() {}

    // MARK: - Loading

    public func insert(cartridge data: Data) throws {
        let loaded = try GameCartridge(rom: [UInt8](data))
        cartridge = loaded
        reset()
    }

    /// Whether to wake the Color hardware for a cartridge that supports it.
    ///
    /// Dual-mode cartridges — Pokémon Silver among them — run either way, so
    /// this is a real choice rather than a detection. Off, you get the game as
    /// it looked on a 1989 Game Boy.
    public var prefersColor = true { didSet { reset() } }

    public var header: GameCartridge.Header? { cartridge?.header }

    /// Puts the machine into the state the boot ROM leaves it in.
    ///
    /// The boot ROM itself isn't included — it's 256 copyrighted bytes, and the
    /// only thing lost by starting after it is the scrolling logo.
    public func reset() {
        colorMode = (cartridge?.header.supportsColor ?? false) && prefersColor
        // The boot ROM leaves 0x11 in A on a Color, and games read it to decide
        // which mode to configure themselves for.
        cpu = CPU(registers: colorMode ? .afterColorBoot : .afterBoot)
        ppu = PPU()
        ppu.colorMode = colorMode
        cpu.stopHandler = { [weak self] in self?.switchSpeed() }
        timer = SystemTimer()
        joypad = Joypad()
        apu = APU()
        workRAM = [UInt8](repeating: 0, count: 0x8000)
        workRAMBank = 1
        highRAM = [UInt8](repeating: 0, count: 0x7F)
        serialOutput = ""
        carriedCycles = 0
        doubleSpeed = false
        speedSwitchArmed = false
        hdmaActive = false
    }

    /// `STOP` with the switch armed is how a Color game changes gear.
    private func switchSpeed() {
        guard colorMode, speedSwitchArmed else { return }
        speedSwitchArmed = false
        doubleSpeed.toggle()
    }

    // MARK: - Running

    /// Addresses held at fixed values, rewritten once per frame.
    ///
    /// Empty in the overwhelmingly common case, and the check below is one
    /// `isEmpty` per frame, so this costs nothing when unused.
    public var cheats: [Cheat] = []

    /// Writes every enabled cheat, once.
    ///
    /// Once per frame rather than once per instruction because that's what the
    /// hardware did, and games depend on the difference: a value the game
    /// recomputes constantly will flicker rather than stick, and one that's
    /// read shortly after a frame boundary — like the species of the encounter
    /// about to start — takes reliably.
    ///
    /// This writes straight into work RAM rather than going through the bus.
    /// The bus would route `$A000-$BFFF` through the mapper, and a cheat is
    /// meant to poke memory, not to operate the cartridge's bank latches.
    private func applyCheats() {
        for cheat in cheats where cheat.isEnabled {
            switch cheat.address {
            case 0xC000...0xCFFF:
                workRAM[Int(cheat.address & 0x0FFF)] = cheat.value
            case 0xD000...0xDFFF:
                // The bank the cheat names, not whichever one happens to be
                // paged in when the frame ends.
                let bank = max(1, min(cheat.bank, 7))
                workRAM[bank * 0x1000 + Int(cheat.address & 0x0FFF)] = cheat.value
            case 0xFF80...0xFFFE:
                highRAM[Int(cheat.address - 0xFF80)] = cheat.value
            case 0xA000...0xBFFF:
                cartridge?.writeRAM(cheat.address, cheat.value)
            default:
                break  // ROM, VRAM, OAM and IO are not what these codes address.
            }
        }
    }

    public func runFrame() {
        guard cartridge != nil else { return }

        if !cheats.isEmpty { applyCheats() }

        carriedCycles += PPU.clocksPerFrame
        while carriedCycles > 0 {
            // Every bus access ticks the rest of the machine as it happens, so
            // by the time `step` returns, most of the instruction's time has
            // already elapsed. What's left is its internal cycles.
            accessCycles = 0
            let clocks = cpu.step(self) * 4
            advance(clocks - accessCycles)
            // The frame budget is in video clocks. At double speed the CPU gets
            // through twice as many of its own for the same picture, which is
            // the entire point of the mode.
            carriedCycles -= doubleSpeed ? clocks / 2 : clocks
        }
    }

    /// Runs the other chips forward by `clocks`.
    private func advance(_ clocks: Int) {
        guard clocks > 0 else { return }

        // The divider runs off the CPU clock, so it doubles along with it.
        if timer.step(clocks) { cpu.request(.timer) }

        // The video and sound hardware do not. They see half as many clocks per
        // CPU cycle at double speed, which is what gives a game more processing
        // time per scanline rather than a faster game.
        let videoClocks = doubleSpeed ? clocks / 2 : clocks
        cpu.interruptFlags |= ppu.step(videoClocks)
        if ppu.enteredHBlank { stepHDMA() }

        // The sound hardware's frame sequencer is driven by a bit of the
        // divider rather than by a counter of its own, so it's read here after
        // the timer has advanced. At double speed it moves up one bit, so the
        // sequencer keeps running at 512 Hz while the divider underneath it
        // runs at twice the rate.
        let dividerBit: UInt16 = doubleSpeed ? 0x2000 : 0x1000
        apu.step(videoClocks, dividerBit: timer.counter & dividerBit != 0)
    }

    /// One M-cycle, charged to the bus access that caused it.
    ///
    /// Advancing the timer and the PPU *during* an instruction rather than
    /// after it is the difference between knowing how long something took and
    /// knowing when within it each memory access landed. Blargg's `mem_timing`
    /// exists specifically to tell those two apart, and a game that reads a
    /// hardware register mid-instruction can tell as well.
    @inline(__always)
    private func tick() {
        guard !suppressTiming else { return }
        accessCycles += 4
        advance(4)
    }

    /// Runs until the given predicate holds or the frame budget runs out.
    /// Used by the test ROMs, which report through the serial port and have no
    /// notion of being finished.
    @discardableResult
    public func run(frames: Int, until stop: (GameBoy) -> Bool = { _ in false }) -> Bool {
        for _ in 0..<frames {
            runFrame()
            if stop(self) { return true }
        }
        return false
    }

    public var framebuffer: [UInt32] { ppu.frontBuffer }

    /// What the four shades look like, and whether frames blend into each other.
    public var palette: ScreenPalette {
        get { ppu.palette }
        set { ppu.palette = newValue }
    }

    public var ghosting: Bool {
        get { ppu.ghosting }
        set { ppu.ghosting = newValue }
    }

    public func set(_ button: ConsoleButton, pressed: Bool) {
        if joypad.set(button, pressed: pressed) { cpu.request(.joypad) }
    }

    public func drainAudio() -> [Float] { apu.drain() }

    public func clearSerialOutput() { serialOutput = "" }

    // MARK: - Memory map

    public func read(_ address: UInt16) -> UInt8 {
        tick()
        switch address {
        case 0x0000...0x7FFF:
            return cartridge?.read(address) ?? 0xFF
        case 0x8000...0x9FFF:
            return ppu.vram[ppu.vramBank * 0x2000 + Int(address & 0x1FFF)]
        case 0xA000...0xBFFF:
            return cartridge?.readRAM(address) ?? 0xFF
        case 0xC000...0xDFFF, 0xE000...0xFDFF:
            // Echo RAM shares the decode: the address decoder simply doesn't
            // check bit 13, so 0xE000 upward is the same chip seen twice.
            // Documented as prohibited, and used anyway by a few games.
            return workRAM[workRAMOffset(address)]
        case 0xFE00...0xFE9F:
            return ppu.oam[Int(address - 0xFE00)]
        case 0xFEA0...0xFEFF:
            // Not wired to anything.
            return 0x00
        case 0xFF00...0xFF7F:
            return readIO(address)
        case 0xFF80...0xFFFE:
            return highRAM[Int(address - 0xFF80)]
        default:
            return cpu.interruptEnable
        }
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        tick()
        switch address {
        case 0x0000...0x7FFF:
            cartridge?.writeControl(address, value)
        case 0x8000...0x9FFF:
            ppu.vram[ppu.vramBank * 0x2000 + Int(address & 0x1FFF)] = value
        case 0xA000...0xBFFF:
            cartridge?.writeRAM(address, value)
        case 0xC000...0xDFFF, 0xE000...0xFDFF:
            workRAM[workRAMOffset(address)] = value
        case 0xFE00...0xFE9F:
            ppu.oam[Int(address - 0xFE00)] = value
        case 0xFEA0...0xFEFF:
            break
        case 0xFF00...0xFF7F:
            writeIO(address, value)
        case 0xFF80...0xFFFE:
            highRAM[Int(address - 0xFF80)] = value
        default:
            cpu.interruptEnable = value
        }
    }

    /// The low half is fixed to bank 0; the high half follows SVBK, where a
    /// written 0 means bank 1.
    @inline(__always)
    private func workRAMOffset(_ address: UInt16) -> Int {
        let offset = Int(address & 0x0FFF)
        return address & 0x1000 == 0 ? offset : workRAMBank * 0x1000 + offset
    }

    // MARK: - Hardware registers

    private func readIO(_ address: UInt16) -> UInt8 {
        switch address {
        case 0xFF00: joypad.read()
        case 0xFF01: serialData
        case 0xFF02: serialControl | 0x7E
        case 0xFF04: timer.divider
        case 0xFF05: timer.tima
        case 0xFF06: timer.modulo
        case 0xFF07: timer.control | 0xF8
        // The top three bits of IF aren't connected and read high, which is why
        // so much code writes 0xE0-masked values back to it.
        case 0xFF0F: cpu.interruptFlags | 0xE0
        case 0xFF10...0xFF3F: apu.read(address)
        case 0xFF40: ppu.control
        case 0xFF41: ppu.status
        case 0xFF42: ppu.scrollY
        case 0xFF43: ppu.scrollX
        case 0xFF44: ppu.line
        case 0xFF45: ppu.lineCompare
        case 0xFF47: ppu.backgroundPalette
        case 0xFF48: ppu.objectPalette0
        case 0xFF49: ppu.objectPalette1
        case 0xFF4A: ppu.windowY
        case 0xFF4B: ppu.windowX
        // Everything below only exists on the Color, and reads as 0xFF on a
        // DMG — which is how a dual-mode game detects which machine it's on.
        case 0xFF4D: colorMode ? (doubleSpeed ? 0x80 : 0x00) | (speedSwitchArmed ? 0x01 : 0) | 0x7E : 0xFF
        case 0xFF4F: colorMode ? UInt8(ppu.vramBank) | 0xFE : 0xFF
        case 0xFF51...0xFF54: 0xFF
        case 0xFF55: colorMode ? hdmaStatus : 0xFF
        case 0xFF68: colorMode ? ppu.backgroundPaletteIndex | 0x40 : 0xFF
        case 0xFF69: colorMode ? ppu.backgroundPaletteData[Int(ppu.backgroundPaletteIndex & 0x3F)] : 0xFF
        case 0xFF6A: colorMode ? ppu.objectPaletteIndex | 0x40 : 0xFF
        case 0xFF6B: colorMode ? ppu.objectPaletteData[Int(ppu.objectPaletteIndex & 0x3F)] : 0xFF
        case 0xFF70: colorMode ? UInt8(workRAMBank) | 0xF8 : 0xFF
        default: unmappedIO[Int(address & 0x7F)]
        }
    }

    private func writeIO(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0xFF00: joypad.write(value)
        case 0xFF01: serialData = value
        case 0xFF02: writeSerialControl(value)
        case 0xFF04: timer.writeDivider()
        case 0xFF05: timer.writeTIMA(value)
        case 0xFF06: timer.modulo = value
        case 0xFF07: timer.writeControl(value)
        case 0xFF0F: cpu.interruptFlags = value & 0x1F
        case 0xFF10...0xFF3F: apu.write(address, value)
        case 0xFF40: ppu.control = value
        case 0xFF41: ppu.status = value
        case 0xFF42: ppu.scrollY = value
        case 0xFF43: ppu.scrollX = value
        // LY is read-only; writing it resets the counter on hardware, but no
        // game does it deliberately and honouring it breaks more than it fixes.
        case 0xFF44: break
        case 0xFF45: ppu.lineCompare = value
        case 0xFF46: performOAMDMA(from: value)
        case 0xFF47: ppu.backgroundPalette = value
        case 0xFF48: ppu.objectPalette0 = value
        case 0xFF49: ppu.objectPalette1 = value
        case 0xFF4A: ppu.windowY = value
        case 0xFF4B: ppu.windowX = value
        case 0xFF4D:
            if colorMode { speedSwitchArmed = value & 0x01 != 0 }
        case 0xFF4F:
            if colorMode { ppu.vramBank = Int(value & 0x01) }
        case 0xFF51: hdmaSource = (hdmaSource & 0x00FF) | (UInt16(value) << 8)
        case 0xFF52: hdmaSource = (hdmaSource & 0xFF00) | UInt16(value & 0xF0)
        case 0xFF53: hdmaDestination = (hdmaDestination & 0x00FF) | (UInt16(value & 0x1F) << 8)
        case 0xFF54: hdmaDestination = (hdmaDestination & 0xFF00) | UInt16(value & 0xF0)
        case 0xFF55:
            if colorMode { startHDMA(value) }
        case 0xFF68:
            if colorMode { ppu.backgroundPaletteIndex = value }
        case 0xFF69:
            if colorMode { writePalette(&ppu.backgroundPaletteData, &ppu.backgroundPaletteIndex, value) }
        case 0xFF6A:
            if colorMode { ppu.objectPaletteIndex = value }
        case 0xFF6B:
            if colorMode { writePalette(&ppu.objectPaletteData, &ppu.objectPaletteIndex, value) }
        case 0xFF70:
            // Bank 0 isn't selectable in the high half; writing 0 gets bank 1.
            if colorMode { workRAMBank = max(Int(value & 0x07), 1) }
        default: unmappedIO[Int(address & 0x7F)] = value
        }
    }

    /// Palette memory is written a byte at a time through a moving index, and
    /// bit 7 of the index register makes it step on its own — so a game can
    /// blast all 64 bytes without touching the index again.
    private func writePalette(_ data: inout [UInt8], _ index: inout UInt8, _ value: UInt8) {
        data[Int(index & 0x3F)] = value
        if index & 0x80 != 0 {
            index = (index & 0x80) | ((index &+ 1) & 0x3F)
        }
    }

    // MARK: - VRAM transfer

    private var hdmaStatus: UInt8 {
        // Bit 7 set means "no transfer running", which is the opposite of what
        // it looks like.
        hdmaActive ? UInt8((hdmaRemaining / 16) - 1) : 0xFF
    }

    private func startHDMA(_ value: UInt8) {
        let length = (Int(value & 0x7F) + 1) * 16

        guard value & 0x80 != 0 else {
            if hdmaActive {
                // Writing with bit 7 clear during a transfer cancels it rather
                // than starting a new one.
                hdmaActive = false
                return
            }
            // General purpose: the whole block at once, with the CPU halted.
            // Done instantly here; the cost is that a game timing one against
            // the scanline counter would see it finish early.
            copyHDMA(bytes: length)
            hdmaRemaining = 0
            return
        }

        hdmaRemaining = length
        hdmaActive = true
    }

    /// The horizontal-blank variant moves sixteen bytes per line, which is the
    /// only way to push a whole screen of new tiles in during a frame — and the
    /// reason Color games can scroll layered backgrounds a DMG could not.
    private func stepHDMA() {
        guard hdmaActive else { return }
        copyHDMA(bytes: 16)
        hdmaRemaining -= 16
        if hdmaRemaining <= 0 { hdmaActive = false }
    }

    private func copyHDMA(bytes: Int) {
        suppressTiming = true
        for _ in 0..<bytes {
            let value = read(hdmaSource)
            ppu.vram[ppu.vramBank * 0x2000 + Int(hdmaDestination & 0x1FFF)] = value
            hdmaSource &+= 1
            hdmaDestination &+= 1
        }
        suppressTiming = false
    }

    /// Sprite attributes are copied wholesale rather than written one byte at a
    /// time, because there isn't enough time in VBlank to do it with the CPU.
    ///
    /// Done instantly here. On hardware it takes 160 M-cycles during which the
    /// CPU can only reach high RAM — which is exactly why every game's DMA
    /// routine is copied *into* high RAM and busy-waits there.
    private func performOAMDMA(from page: UInt8) {
        let base = UInt16(page) << 8
        suppressTiming = true
        for offset in 0..<0xA0 {
            ppu.oam[offset] = read(base + UInt16(offset))
        }
        suppressTiming = false
    }

    /// Nothing is connected to the link port, so a transfer completes instantly
    /// and shifts in 0xFF — the idle state of a floating line.
    private func writeSerialControl(_ value: UInt8) {
        serialControl = value
        guard value & 0x80 != 0 else { return }

        serialOutput.append(Character(UnicodeScalar(serialData)))
        serialData = 0xFF
        serialControl &= ~0x80
        cpu.request(.serial)
    }

    // MARK: - Persistence

    public var batteryRAM: Data? {
        get { cartridge?.batteryRAM.map { Data($0) } }
        set { cartridge?.batteryRAM = newValue.map { [UInt8]($0) } }
    }

    /// A whole-machine snapshot.
    ///
    /// The ROM isn't included: it's up to 8 MB, it can't have changed, and the
    /// title check below catches the one case that matters — loading a state
    /// that belongs to a different game.
    private struct Snapshot: Codable {
        var title: String
        var cpu: CPU
        var ppu: PPU
        var timer: SystemTimer
        var apu: APU
        var joypad: Joypad
        // `Data` rather than `[UInt8]`: a binary plist stores it as raw bytes,
        // where an array of integers becomes one boxed object per byte.
        var workRAM: Data
        var highRAM: Data
        var unmappedIO: Data
        var mapper: MapperState
        var carriedCycles: Int

        // The Color's additions. Leaving these out is invisible in a screenshot
        // taken straight after a restore and obvious a second later, when the
        // game reads back a work RAM bank it never selected.
        var colorMode: Bool
        var workRAMBank: Int
        var doubleSpeed: Bool
        var speedSwitchArmed: Bool
        var hdmaSource: UInt16
        var hdmaDestination: UInt16
        var hdmaRemaining: Int
        var hdmaActive: Bool
    }

    /// Binary rather than JSON, and compressed.
    ///
    /// JSON wrote every byte of RAM as a decimal number with a comma after it,
    /// which is fine once when someone taps Save and hopeless twenty times a
    /// second for rewind. A binary property list stores `Data` as bytes, and
    /// the RAM of a running game is mostly zeroes, so it compresses hard.
    public func saveState() throws -> Data {
        guard let cartridge else { throw SystemError.corruptSaveState }
        let snapshot = Snapshot(
            title: cartridge.header.title,
            cpu: cpu, ppu: ppu, timer: timer, apu: apu, joypad: joypad,
            workRAM: Data(workRAM), highRAM: Data(highRAM), unmappedIO: Data(unmappedIO),
            mapper: cartridge.state, carriedCycles: carriedCycles,
            colorMode: colorMode, workRAMBank: workRAMBank,
            doubleSpeed: doubleSpeed, speedSwitchArmed: speedSwitchArmed,
            hdmaSource: hdmaSource, hdmaDestination: hdmaDestination,
            hdmaRemaining: hdmaRemaining, hdmaActive: hdmaActive
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(snapshot)
        return (try? (plist as NSData).compressed(using: .zlib) as Data) ?? plist
    }

    public func loadState(_ data: Data) throws {
        guard let cartridge else { throw SystemError.corruptSaveState }

        // Uncompressed states are accepted too, so a file written before
        // compression existed still loads.
        let plist = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        guard let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: plist),
              snapshot.title == cartridge.header.title
        else { throw SystemError.corruptSaveState }

        cpu = snapshot.cpu
        ppu = snapshot.ppu
        timer = snapshot.timer
        joypad = snapshot.joypad
        apu = snapshot.apu
        workRAM = [UInt8](snapshot.workRAM)
        highRAM = [UInt8](snapshot.highRAM)
        unmappedIO = [UInt8](snapshot.unmappedIO)
        cartridge.state = snapshot.mapper
        carriedCycles = snapshot.carriedCycles

        colorMode = snapshot.colorMode
        workRAMBank = snapshot.workRAMBank
        doubleSpeed = snapshot.doubleSpeed
        speedSwitchArmed = snapshot.speedSwitchArmed
        hdmaSource = snapshot.hdmaSource
        hdmaDestination = snapshot.hdmaDestination
        hdmaRemaining = snapshot.hdmaRemaining
        hdmaActive = snapshot.hdmaActive

        // The decoded CPU is a fresh object, so the hook the bus installed on
        // the old one doesn't come with it.
        cpu.stopHandler = { [weak self] in self?.switchSpeed() }
    }
}

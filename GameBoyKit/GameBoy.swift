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
    private var cartridge: GameCartridge?

    private var workRAM = [UInt8](repeating: 0, count: 0x2000)
    private var highRAM = [UInt8](repeating: 0, count: 0x7F)
    /// Registers this core doesn't model yet — chiefly the four sound channels.
    /// Storing the writes lets a game read back what it wrote, which is all most
    /// of them check for.
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

    public var header: GameCartridge.Header? { cartridge?.header }

    /// Puts the machine into the state the boot ROM leaves it in.
    ///
    /// The boot ROM itself isn't included — it's 256 copyrighted bytes, and the
    /// only thing lost by starting after it is the scrolling logo.
    public func reset() {
        cpu = CPU()
        ppu = PPU()
        timer = SystemTimer()
        joypad = Joypad()
        workRAM = [UInt8](repeating: 0, count: 0x2000)
        highRAM = [UInt8](repeating: 0, count: 0x7F)
        serialOutput = ""
        carriedCycles = 0
    }

    // MARK: - Running

    public func runFrame() {
        guard cartridge != nil else { return }

        carriedCycles += PPU.clocksPerFrame
        while carriedCycles > 0 {
            // Every bus access ticks the rest of the machine as it happens, so
            // by the time `step` returns, most of the instruction's time has
            // already elapsed. What's left is its internal cycles.
            accessCycles = 0
            let clocks = cpu.step(self) * 4
            advance(clocks - accessCycles)
            carriedCycles -= clocks
        }
    }

    /// Runs the other chips forward by `clocks`.
    private func advance(_ clocks: Int) {
        guard clocks > 0 else { return }
        if timer.step(clocks) { cpu.request(.timer) }
        cpu.interruptFlags |= ppu.step(clocks)
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

    public func set(_ button: ConsoleButton, pressed: Bool) {
        if joypad.set(button, pressed: pressed) { cpu.request(.joypad) }
    }

    /// Not yet implemented — the sound hardware is the next piece of work.
    /// Returning nothing is honest; returning silence at the right length would
    /// hide the gap behind a working-looking audio clock.
    public func drainAudio() -> [Float] { [] }

    public func clearSerialOutput() { serialOutput = "" }

    // MARK: - Memory map

    public func read(_ address: UInt16) -> UInt8 {
        tick()
        switch address {
        case 0x0000...0x7FFF:
            return cartridge?.read(address) ?? 0xFF
        case 0x8000...0x9FFF:
            return ppu.vram[Int(address & 0x1FFF)]
        case 0xA000...0xBFFF:
            return cartridge?.readRAM(address) ?? 0xFF
        case 0xC000...0xDFFF:
            return workRAM[Int(address & 0x1FFF)]
        case 0xE000...0xFDFF:
            // Echo RAM: the address decoder simply doesn't check bit 13, so
            // this range is the same chip seen twice. Documented as prohibited,
            // and used anyway by a few games.
            return workRAM[Int(address & 0x1FFF)]
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
            ppu.vram[Int(address & 0x1FFF)] = value
        case 0xA000...0xBFFF:
            cartridge?.writeRAM(address, value)
        case 0xC000...0xDFFF, 0xE000...0xFDFF:
            workRAM[Int(address & 0x1FFF)] = value
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
        default: unmappedIO[Int(address & 0x7F)] = value
        }
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
        var joypad: Joypad
        var workRAM: [UInt8]
        var highRAM: [UInt8]
        var unmappedIO: [UInt8]
        var mapper: MapperState
        var carriedCycles: Int
    }

    public func saveState() throws -> Data {
        guard let cartridge else { throw SystemError.corruptSaveState }
        let snapshot = Snapshot(
            title: cartridge.header.title,
            cpu: cpu, ppu: ppu, timer: timer, joypad: joypad,
            workRAM: workRAM, highRAM: highRAM, unmappedIO: unmappedIO,
            mapper: cartridge.state, carriedCycles: carriedCycles
        )
        return try JSONEncoder().encode(snapshot)
    }

    public func loadState(_ data: Data) throws {
        guard let cartridge else { throw SystemError.corruptSaveState }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.title == cartridge.header.title
        else { throw SystemError.corruptSaveState }

        cpu = snapshot.cpu
        ppu = snapshot.ppu
        timer = snapshot.timer
        joypad = snapshot.joypad
        workRAM = snapshot.workRAM
        highRAM = snapshot.highRAM
        unmappedIO = snapshot.unmappedIO
        cartridge.state = snapshot.mapper
        carriedCycles = snapshot.carriedCycles
    }
}

//
//  HardwareTests.swift
//  GameBoyKitTests
//

import Testing
import Foundation

/// Where the fetched ROMs are.
///
/// Kept outside the suite because a suite's own trait can't refer back to the
/// type it's attached to — the macro would have to expand to know the answer.
enum TestROMs {
    static let directory: URL? = {
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: "roms", withExtension: nil) { return url }

        // Falling back to the source tree keeps this working when the bundle
        // hasn't picked the folder up.
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Resources/roms")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }()

    static var available: Bool {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return contents.contains { $0.hasSuffix(".gb") }
    }

    private final class BundleToken {}
}

/// Runs the machine against the community's hardware test ROMs.
///
/// The SM83 suite next door proves the CPU one instruction at a time with the
/// rest of the console absent. These do the opposite: they run real programs on
/// the assembled machine, and they fail for reasons no unit test would reach —
/// an interrupt arriving on the wrong cycle, a memory read landing at the wrong
/// point inside an instruction, a sprite drawn one pixel too far left.
///
/// Fetch them with `./scripts/fetch-roms.sh`; they aren't committed.
@Suite("Hardware test ROMs", .enabled(if: TestROMs.available))
struct HardwareTests {

    // MARK: - Fixtures

    static func machine(_ name: String) throws -> GameBoy {
        let url = try #require(
            TestROMs.directory?.appending(path: name), "Run ./scripts/fetch-roms.sh"
        )
        let system = GameBoy()
        try system.insert(cartridge: try Data(contentsOf: url))
        return system
    }

    /// Runs until the ROM reports through the link port, or gives up.
    ///
    /// Blargg's tests print their results a character at a time to the serial
    /// port, which is why they work with no display: a failure names the
    /// sub-test that broke rather than leaving a wrong picture to interpret.
    static func serialResult(of rom: String, frames: Int) throws -> String {
        let system = try machine(rom)
        system.run(frames: frames) { $0.serialOutput.contains("Passed")
            || $0.serialOutput.contains("Failed") }
        return system.serialOutput
    }

    /// A palette-independent digest of the screen, so that changing the display
    /// colours can't turn a picture test red.
    static func screenChecksum(of system: GameBoy) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for pixel in system.framebuffer {
            let shade = UInt8(ScreenPalette.dmg.shades.firstIndex(of: pixel) ?? 0)
            hash = (hash ^ UInt64(shade)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - CPU

    @Test("Blargg cpu_instrs — all 11 groups")
    func cpuInstructions() throws {
        let output = try Self.serialResult(of: "cpu_instrs.gb", frames: 6000)
        #expect(output.contains("Passed all"), "cpu_instrs reported:\n\(output)")
    }

    @Test("Blargg instr_timing — every instruction's cycle count")
    func instructionTiming() throws {
        let output = try Self.serialResult(of: "instr_timing.gb", frames: 1200)
        #expect(output.contains("Passed"), "instr_timing reported:\n\(output)")
    }

    /// The one that forced the bus to advance the clock per access rather than
    /// per instruction: it checks *when inside* an instruction each read and
    /// write lands, which a core that only knows totals cannot get right.
    @Test("Blargg mem_timing — when each access happens within an instruction")
    func memoryTiming() throws {
        let output = try Self.serialResult(of: "mem_timing.gb", frames: 1200)
        #expect(output.contains("Passed all"), "mem_timing reported:\n\(output)")
    }

    // MARK: - Picture

    /// dmg-acid2 packs the PPU's every edge case into one frame — sprite
    /// priority, the ten-per-line limit, 8×16 tiles, both flips, the window's
    /// separate line counter, and the background-off case. Anything wrong shows
    /// up as a specific deformity in the face it draws.
    ///
    /// The expected checksum was recorded from a run verified pixel-for-pixel
    /// against Matt Currie's published reference image: 0 of 23,040 pixels
    /// differed.
    @Test("dmg-acid2 renders exactly")
    func pictureProcessing() throws {
        let system = try Self.machine("dmg-acid2.gb")
        system.run(frames: 120)
        #expect(Self.screenChecksum(of: system) == 0xF272_A8FF_E3DB_4C16)
    }

    // MARK: - Save states

    /// A state has to reproduce the future, not just the picture.
    ///
    /// This is what rewind rests on: it restores a state twenty times a second
    /// and plays forward from it, so anything left out of a snapshot shows up as
    /// the game quietly diverging. Comparing a screen sixty frames *after* the
    /// restore catches state that a screenshot taken immediately would not.
    @Test("A restored state replays identically")
    func saveStateFidelity() throws {
        let system = try Self.machine("cpu_instrs.gb")
        system.run(frames: 300)

        let state = try system.saveState()
        system.run(frames: 60)
        let withoutRestore = Self.screenChecksum(of: system)

        try system.loadState(state)
        system.run(frames: 60)
        let afterRestore = Self.screenChecksum(of: system)

        #expect(withoutRestore == afterRestore, "the machine diverged after restoring")
    }

    /// States are written continuously during rewind, so their size is a
    /// feature. This one caught the audio buffer being serialised: states were
    /// 847 KB and took 236 ms, which is unusable at twenty a second.
    @Test("A state is small enough to take twenty times a second")
    func saveStateSize() throws {
        let system = try Self.machine("cpu_instrs.gb")
        system.run(frames: 300)
        let state = try system.saveState()
        #expect(state.count < 64 * 1024, "a save state is \(state.count) bytes")
    }

    /// The halt bug — `HALT` executed with interrupts disabled and one already
    /// pending, which makes the next byte run twice.
    ///
    /// This ROM reports on screen rather than over the link, so the assertion is
    /// a digest of a screen that was read by eye and says "Passed". If it ever
    /// fails, render `framebuffer` to a PNG and look at it: the ROM prints a
    /// table of IE/IF/DE values above the verdict, and the wrong row identifies
    /// the case that broke.
    @Test("Blargg halt_bug")
    func haltBug() throws {
        let system = try Self.machine("halt_bug.gb")
        system.run(frames: 900)
        #expect(Self.screenChecksum(of: system) == 0xED0D_43F0_501A_9E36)
    }
}

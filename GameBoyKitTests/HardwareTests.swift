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
        let finished = system.run(frames: frames) {
            $0.serialOutput.contains("Passed") || $0.serialOutput.contains("Failed")
        }

        // The verdict arrives a character at a time over several frames, so
        // stopping the instant "Passed" appears cuts the sentence off mid-word
        // and "Passed all tests" reads as "Passed ". Sixty more frames lets the
        // rest of the line land.
        if finished { system.run(frames: 60) }
        return system.serialOutput
    }

    /// A digest of the picture that survives a change of palette, of colour
    /// correction, or of the machine being in colour at all.
    ///
    /// Ranks the distinct colours on screen by brightness and hashes those
    /// ranks, so it describes the picture's structure rather than its exact
    /// values — which is what a rendering test should be asserting anyway.
    static func structuralChecksum(of system: GameBoy) -> UInt64 {
        let pixels = system.framebuffer
        let ranked = Set(pixels).sorted { luminance($0) > luminance($1) }
        var rank: [UInt32: UInt8] = [:]
        for (index, colour) in ranked.enumerated() { rank[colour] = UInt8(index) }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for pixel in pixels {
            hash = (hash ^ UInt64(rank[pixel] ?? 0)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func luminance(_ colour: UInt32) -> Double {
        let r = Double((colour >> 16) & 0xFF)
        let g = Double((colour >> 8) & 0xFF)
        let b = Double(colour & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b
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
        #expect(Self.structuralChecksum(of: system) == 0xF272_A8FF_E3DB_4C16)
    }

    /// cgb-acid2 is the colour hardware's equivalent of dmg-acid2, and covers
    /// the parts a monochrome test cannot reach: the second VRAM bank, the
    /// per-tile attribute byte with its palette, bank and flip bits, object
    /// palettes, and the priority rules — which the Color rearranges rather
    /// than extends.
    ///
    /// Verified against Matt Currie's published reference: 0 of 23,040 pixels
    /// differed structurally. The two images aren't identical in value, because
    /// the reference scales the hardware's five bits straight to eight and this
    /// applies the colour correction a real screen implied.
    @Test("cgb-acid2 renders exactly")
    func colorPictureProcessing() throws {
        let system = try Self.machine("cgb-acid2.gbc")
        system.run(frames: 200)
        #expect(system.colorMode, "the cartridge didn't start in Color mode")
        #expect(Self.structuralChecksum(of: system) == 0xFC38_EAEC_92FD_ECF0)
    }

    /// The same cartridge, told to stay monochrome. Dual-mode games are meant
    /// to run either way, and the DMG path has to survive the Color one being
    /// bolted alongside it.
    @Test("A Color cartridge still runs in monochrome")
    func colorCartridgeInMonochrome() throws {
        let system = try Self.machine("cgb-acid2.gbc")
        system.prefersColor = false
        system.run(frames: 200)
        #expect(!system.colorMode)

        let shades = Set(system.framebuffer)
        #expect(shades.count <= 4, "\(shades.count) colours on a monochrome screen")
        #expect(shades.allSatisfy { ScreenPalette.dmg.shades.contains($0) })
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
        let withoutRestore = Self.structuralChecksum(of: system)

        try system.loadState(state)
        system.run(frames: 60)
        let afterRestore = Self.structuralChecksum(of: system)

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
    /// This ROM declares Color support, so it runs on the Color hardware and
    /// prints in white on black rather than in green. Its verdict was read by
    /// eye in that mode and says "Passed"; the assertion is a digest of it. If it ever
    /// fails, render `framebuffer` to a PNG and look at it: the ROM prints a
    /// table of IE/IF/DE values above the verdict, and the wrong row identifies
    /// the case that broke.
    @Test("Blargg halt_bug")
    func haltBug() throws {
        let system = try Self.machine("halt_bug.gb")
        system.run(frames: 900)
        #expect(Self.structuralChecksum(of: system) == 0x9EDE_0ADA_8CE1_8374)
    }
}

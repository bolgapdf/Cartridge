//
//  APUTests.swift
//  GameBoyKitTests
//

import Testing
import Foundation

/// Drives the sound hardware directly through the bus, with no ROM involved.
///
/// Audio is easy to get plausibly wrong: something comes out, it sounds roughly
/// like a Game Boy, and the pitch is a semitone off or the stream runs slightly
/// fast and drifts out of sync over a minute. These check the things listening
/// won't catch.
@Suite("Sound hardware")
struct APUTests {

    /// A machine running nothing. The ROM is all zeroes, which decode as `NOP`,
    /// so the CPU idles while the registers below do the work.
    static func idleMachine() throws -> GameBoy {
        var rom = [UInt8](repeating: 0, count: 0x8000)
        rom[0x0147] = 0x00      // no mapper
        rom[0x0148] = 0x00      // 32 KB
        rom[0x0149] = 0x00      // no RAM

        let system = GameBoy()
        try system.insert(cartridge: Data(rom))
        return system
    }

    /// Sets channel 1 to a 512 Hz square at full volume, on both sides.
    static func startTone(_ system: GameBoy) {
        system.write(0xFF26, 0x80)      // NR52: power on
        system.write(0xFF25, 0xFF)      // NR51: every channel to both sides
        system.write(0xFF24, 0x77)      // NR50: full volume both sides
        system.write(0xFF11, 0x80)      // NR11: 50% duty, no length
        system.write(0xFF12, 0xF0)      // NR12: volume 15, envelope off
        system.write(0xFF13, 0x00)      // NR13: frequency low
        // NR14: trigger, and frequency high — 0x700 gives
        // 4194304 / (32 × (2048 − 1792)) = 512 Hz exactly.
        system.write(0xFF14, 0x87)
    }

    static func channels(_ samples: [Float]) -> (left: [Float], right: [Float]) {
        var left: [Float] = [], right: [Float] = []
        for index in stride(from: 0, to: samples.count - 1, by: 2) {
            left.append(samples[index])
            right.append(samples[index + 1])
        }
        return (left, right)
    }

    // MARK: - Tests

    /// The stream has to come out at exactly the rate the audio device consumes
    /// it. A percent of error is inaudible for a second and a dropout a minute
    /// later, so this is checked against the console's real frame rate rather
    /// than a round 60.
    @Test("Produces 48 kHz in step with the video frame rate")
    func sampleRate() throws {
        let system = try Self.idleMachine()
        Self.startTone(system)

        var produced = 0
        for _ in 0..<60 {
            system.runFrame()
            produced += system.drainAudio().count
        }

        // 60 frames at 59.7275 Hz is 1.00456 seconds: 48,219 stereo pairs.
        let expected = 48_000.0 * (60.0 / GameBoy.frameRate) * 2
        #expect(abs(Double(produced) - expected) < 100,
                "produced \(produced) samples, expected about \(Int(expected))")
    }

    @Test("A triggered square channel oscillates at the programmed frequency")
    func squareWave() throws {
        let system = try Self.idleMachine()
        Self.startTone(system)

        system.runFrame()
        let (left, _) = Self.channels(system.drainAudio())
        try #require(!left.isEmpty)

        #expect(left.map(abs).max() ?? 0 > 0.1, "the channel is silent")

        // 512 Hz over one 16.74 ms frame is 8.6 cycles, so about 17 crossings.
        var crossings = 0
        for index in 1..<left.count where (left[index] < 0) != (left[index - 1] < 0) {
            crossings += 1
        }
        #expect((14...22).contains(crossings),
                "\(crossings) zero crossings — expected about 17 for 512 Hz")
    }

    /// Both sides are fed identically here, so any difference means the panning
    /// register is being read with its halves swapped — a mistake that sounds
    /// completely normal in mono.
    @Test("Panning puts a channel on the side NR51 selects")
    func panning() throws {
        let system = try Self.idleMachine()
        Self.startTone(system)
        // Channel 1 to the left only: bit 4 sets left, bit 0 would set right.
        system.write(0xFF25, 0x10)

        // One frame discarded first. Each output sample averages 87 clocks, so
        // the sample containing the write above legitimately carries a little
        // of the old panning — measuring it would be testing the resampler.
        system.runFrame()
        _ = system.drainAudio()

        system.runFrame()
        let (left, right) = Self.channels(system.drainAudio())

        #expect(left.map(abs).max() ?? 0 > 0.1, "nothing on the left")
        #expect(right.map(abs).max() ?? 0 < 0.01, "channel leaked to the right")
    }

    /// The length counter is what stops a note. Without it a game that never
    /// re-triggers leaves a channel sounding forever, which is the classic
    /// symptom of a broken frame sequencer.
    @Test("The length counter silences a channel")
    func lengthCounter() throws {
        let system = try Self.idleMachine()
        Self.startTone(system)
        // NR11: 50% duty with a length load of 62, so two ticks of the 256 Hz
        // length clock — under 8 ms — should end the note.
        system.write(0xFF11, 0xBE)
        system.write(0xFF14, 0xC7)      // trigger with the length counter enabled

        system.runFrame()
        _ = system.drainAudio()

        // A quarter of a second later there should be nothing left.
        for _ in 0..<15 {
            system.runFrame()
            _ = system.drainAudio()
        }
        system.runFrame()
        let (left, _) = Self.channels(system.drainAudio())
        #expect(left.map(abs).max() ?? 0 < 0.01, "the channel is still sounding")
    }

    /// Powering the sound hardware off is a reset, not a mute: every register
    /// reads back as zero afterwards, and writes are ignored until it comes
    /// back on.
    @Test("Powering off clears the registers")
    func powerOff() throws {
        let system = try Self.idleMachine()
        Self.startTone(system)

        system.write(0xFF26, 0x00)
        #expect(system.read(0xFF11) == 0x3F, "NR11 kept its duty bits")
        #expect(system.read(0xFF12) == 0x00, "NR12 kept its envelope")
        #expect(system.read(0xFF24) == 0x00, "NR50 kept its volume")

        // Ignored while off.
        system.write(0xFF12, 0xF0)
        #expect(system.read(0xFF12) == 0x00, "a write got through while powered off")
    }
}

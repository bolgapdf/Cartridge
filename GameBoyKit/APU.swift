//
//  APU.swift
//  GameBoyKit
//

import Foundation

/// The sound hardware: two square channels, a programmable wave channel, and a
/// noise channel.
///
/// There is no mixer worth the name — each channel produces a number from 0 to
/// 15, a DAC turns that into a voltage, and the four voltages are summed onto
/// two output pins. Panning is one bit per channel per side. That's the whole
/// signal path, and it's why Game Boy music has its particular sound: every
/// instrument is one of four fixed timbres.
///
/// Everything is driven from a **frame sequencer** running at 512 Hz, which
/// clocks lengths at 256 Hz, the sweep at 128 Hz, and envelopes at 64 Hz. On
/// hardware it isn't a separate counter at all — it's a bit of the divider,
/// which is why writing to `DIV` can clock a note's length early.
final class APU: Codable {

    /// The output rate the shell asks for. The console's own rate is the CPU
    /// clock, and everything here is a resampling of that.
    static let sampleRate = 48_000.0
    private static let clockRate = 4_194_304.0
    private static let clocksPerSample = clockRate / sampleRate

    /// Starts on. The boot ROM leaves the sound hardware powered up with NR52
    /// reading 0xF1, and since writes to every other register are dropped while
    /// it's off, starting it off silently discards everything a game does until
    /// it happens to write NR52 itself.
    private var enabled = true

    private var channel1 = SquareChannel(hasSweep: true)
    private var channel2 = SquareChannel(hasSweep: false)
    private var channel3 = WaveChannel()
    private var channel4 = NoiseChannel()

    /// NR50: master volume per side, 0–7. Note that 0 is not silence — it's the
    /// quietest of eight steps, so nothing is ever fully muted this way.
    /// The boot ROM leaves both at 7.
    private var leftVolume = 7
    private var rightVolume = 7
    /// NR51: one bit per channel per side. 0xF3 after boot — everything on the
    /// left, and only channels 1 and 2 on the right.
    private var panning: UInt8 = 0xF3
    /// The other two bits of NR50 mix in audio arriving from the cartridge
    /// itself. No released game has the hardware for it, so nothing is done
    /// with them — but they are readable, and a register test notices.
    private var vinFlags: UInt8 = 0

    private var frameStep = 0
    private var lastDividerBit = false

    /// Everything a save state needs, minus `output`.
    ///
    /// That buffer holds samples produced since the shell last drained it. In a
    /// state it is both wrong — resuming shouldn't replay a second of stale
    /// audio — and enormous: an emulator run headlessly without draining had
    /// accumulated 3.8 MB of it, which is what a save state was carrying.
    private enum CodingKeys: String, CodingKey {
        case enabled, channel1, channel2, channel3, channel4
        case leftVolume, rightVolume, panning, vinFlags
        case frameStep, lastDividerBit
        case accumulatedLeft, accumulatedRight, accumulatedClocks, sampleClock
        case capacitorLeft, capacitorRight
    }

    // MARK: - Output

    /// Interleaved stereo, drained by the shell once a frame.
    private var output: [Float] = []
    /// Sums since the last emitted sample, and how many clocks they cover.
    ///
    /// Averaging rather than point-sampling: the channels change state at up to
    /// a megahertz and the output runs at 48 kHz, so taking one instantaneous
    /// reading per output sample would alias badly. Accumulating over the
    /// interval is a box filter, which is crude but is the difference between
    /// a clean square wave and a buzzing one.
    private var accumulatedLeft: Float = 0
    private var accumulatedRight: Float = 0
    private var accumulatedClocks = 0.0
    private var sampleClock = 0.0
    private var capacitorLeft: Float = 0
    private var capacitorRight: Float = 0

    func drain() -> [Float] {
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    // MARK: - Stepping

    /// Advances by `clocks`, given the state of the divider bit that drives the
    /// frame sequencer.
    ///
    /// Taking the bit from the timer rather than counting to 8192 internally is
    /// what makes the `DIV`-write quirk fall out: resetting the divider drives
    /// that bit low, and a falling edge is a frame-sequencer step whether or
    /// not one was due.
    func step(_ clocks: Int, dividerBit: Bool) {
        if lastDividerBit && !dividerBit { stepFrameSequencer() }
        lastDividerBit = dividerBit

        guard enabled else {
            // Powered down, the channels are silent but time still has to pass
            // so the output stays in step with the video frame.
            emitSilence(for: clocks)
            return
        }

        channel1.step(clocks)
        channel2.step(clocks)
        channel3.step(clocks)
        channel4.step(clocks)

        let (left, right) = mix()
        accumulatedLeft += left * Float(clocks)
        accumulatedRight += right * Float(clocks)
        accumulatedClocks += Double(clocks)
        advanceSampleClock(by: clocks)
    }

    private func advanceSampleClock(by clocks: Int) {
        sampleClock += Double(clocks)
        while sampleClock >= Self.clocksPerSample {
            sampleClock -= Self.clocksPerSample
            let divisor = Float(max(accumulatedClocks, 1))
            output.append(highPass(accumulatedLeft / divisor, &capacitorLeft))
            output.append(highPass(accumulatedRight / divisor, &capacitorRight))
            accumulatedLeft = 0
            accumulatedRight = 0
            accumulatedClocks = 0
        }
    }

    /// Removes the DC offset, as the capacitor on the output pin does.
    ///
    /// This isn't cosmetic. A channel that's off but whose DAC is powered sits
    /// at the bottom of its range rather than the middle, so four channels in
    /// that state produce a large constant offset — and every time one switches
    /// on or off, the offset jumps and the speaker clicks. The filter is why
    /// enabling a channel on real hardware is quiet rather than a pop.
    private func highPass(_ input: Float, _ capacitor: inout Float) -> Float {
        let output = input - capacitor
        capacitor = input - output * Self.chargeFactor
        return output
    }

    private static let chargeFactor = Float(pow(0.999958, clocksPerSample))

    private func emitSilence(for clocks: Int) {
        accumulatedClocks += Double(clocks)
        advanceSampleClock(by: clocks)
    }

    /// 512 Hz, eight steps. Lengths on the even steps, sweep on 2 and 6,
    /// envelopes on 7 — an arrangement that spreads the work out rather than
    /// doing everything at once.
    private func stepFrameSequencer() {
        guard enabled else { return }

        switch frameStep {
        case 0, 4:
            clockLengths()
        case 2, 6:
            clockLengths()
            channel1.clockSweep()
        case 7:
            channel1.envelope.clock()
            channel2.envelope.clock()
            channel4.envelope.clock()
        default:
            break
        }
        frameStep = (frameStep + 1) & 7
    }

    private func clockLengths() {
        channel1.clockLength()
        channel2.clockLength()
        channel3.clockLength()
        channel4.clockLength()
    }

    /// True when the next frame-sequencer step will clock lengths. Enabling a
    /// length counter outside that window costs an extra tick on hardware.
    private var nextStepClocksLength: Bool { frameStep % 2 == 1 }

    // MARK: - Mixing

    private func mix() -> (Float, Float) {
        let outputs = (channel1.dacOutput, channel2.dacOutput,
                       channel3.dacOutput, channel4.dacOutput)

        var left: Float = 0
        var right: Float = 0

        // NR51 puts channels 1–4 on the right in bits 0–3 and on the left in
        // bits 4–7. Right first is not a typo — that's the register's layout.
        if panning & 0x01 != 0 { right += outputs.0 }
        if panning & 0x02 != 0 { right += outputs.1 }
        if panning & 0x04 != 0 { right += outputs.2 }
        if panning & 0x08 != 0 { right += outputs.3 }
        if panning & 0x10 != 0 { left += outputs.0 }
        if panning & 0x20 != 0 { left += outputs.1 }
        if panning & 0x40 != 0 { left += outputs.2 }
        if panning & 0x80 != 0 { left += outputs.3 }

        // Four channels summed, then the master volume's eight steps. The
        // quarter keeps a full-scale mix inside ±1.
        left *= Float(leftVolume + 1) / 8 / 4
        right *= Float(rightVolume + 1) / 8 / 4
        return (left, right)
    }

    // MARK: - Registers

    func read(_ address: UInt16) -> UInt8 {
        // Wave RAM stays readable with the sound off, unlike everything else.
        if (0xFF30...0xFF3F).contains(address) {
            return channel3.waveRAM[Int(address - 0xFF30)]
        }

        switch address {
        case 0xFF10: return channel1.sweepRegister | 0x80
        case 0xFF11: return channel1.dutyRegister | 0x3F
        case 0xFF12: return channel1.envelope.register
        case 0xFF14: return (channel1.lengthEnabled ? 0x40 : 0) | 0xBF

        case 0xFF16: return channel2.dutyRegister | 0x3F
        case 0xFF17: return channel2.envelope.register
        case 0xFF19: return (channel2.lengthEnabled ? 0x40 : 0) | 0xBF

        case 0xFF1A: return (channel3.dacEnabled ? 0x80 : 0) | 0x7F
        case 0xFF1C: return UInt8(channel3.volumeCode << 5) | 0x9F
        case 0xFF1E: return (channel3.lengthEnabled ? 0x40 : 0) | 0xBF

        case 0xFF21: return channel4.envelope.register
        case 0xFF22: return channel4.polynomialRegister
        case 0xFF23: return (channel4.lengthEnabled ? 0x40 : 0) | 0xBF

        case 0xFF24: return UInt8(leftVolume << 4 | rightVolume) | vinFlags
        case 0xFF25: return panning
        case 0xFF26:
            // The low four bits report which channels are still sounding, and
            // are read-only. Games poll them to know when a note has finished.
            var status: UInt8 = enabled ? 0x80 : 0
            if channel1.enabled { status |= 0x01 }
            if channel2.enabled { status |= 0x02 }
            if channel3.enabled { status |= 0x04 }
            if channel4.enabled { status |= 0x08 }
            return status | 0x70

        // Frequency registers and length loads are write-only.
        default: return 0xFF
        }
    }

    func write(_ address: UInt16, _ value: UInt8) {
        if (0xFF30...0xFF3F).contains(address) {
            channel3.waveRAM[Int(address - 0xFF30)] = value
            return
        }

        if address == 0xFF26 {
            setPower(value & 0x80 != 0)
            return
        }

        // With the sound off every other register is read-only, and writes are
        // dropped rather than queued. On a DMG the length counters are the one
        // exception, which is why some games load them before powering up.
        guard enabled || isLengthLoad(address) else { return }

        switch address {
        case 0xFF10: channel1.sweepRegister = value
        case 0xFF11: channel1.writeDuty(value)
        case 0xFF12: channel1.writeEnvelope(value)
        case 0xFF13: channel1.writeFrequencyLow(value)
        case 0xFF14: channel1.writeControl(value, extraLengthClock: nextStepClocksLength)

        case 0xFF16: channel2.writeDuty(value)
        case 0xFF17: channel2.writeEnvelope(value)
        case 0xFF18: channel2.writeFrequencyLow(value)
        case 0xFF19: channel2.writeControl(value, extraLengthClock: nextStepClocksLength)

        case 0xFF1A: channel3.writeDACEnable(value)
        case 0xFF1B: channel3.writeLength(value)
        case 0xFF1C: channel3.volumeCode = Int((value >> 5) & 0x03)
        case 0xFF1D: channel3.writeFrequencyLow(value)
        case 0xFF1E: channel3.writeControl(value, extraLengthClock: nextStepClocksLength)

        case 0xFF20: channel4.writeLength(value)
        case 0xFF21: channel4.writeEnvelope(value)
        case 0xFF22: channel4.polynomialRegister = value
        case 0xFF23: channel4.writeControl(value, extraLengthClock: nextStepClocksLength)

        case 0xFF24:
            leftVolume = Int((value >> 4) & 0x07)
            rightVolume = Int(value & 0x07)
            vinFlags = value & 0x88
        case 0xFF25:
            panning = value
        default:
            break
        }
    }

    private func isLengthLoad(_ address: UInt16) -> Bool {
        address == 0xFF11 || address == 0xFF16 || address == 0xFF1B || address == 0xFF20
    }

    /// Powering down clears every register — it is a reset, not a mute.
    private func setPower(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        guard !on else {
            frameStep = 0
            return
        }

        // Wave RAM survives, which is the only thing a game can rely on
        // persisting across a power cycle of the sound hardware.
        let wave = channel3.waveRAM
        channel1 = SquareChannel(hasSweep: true)
        channel2 = SquareChannel(hasSweep: false)
        channel3 = WaveChannel()
        channel3.waveRAM = wave
        channel4 = NoiseChannel()
        leftVolume = 0
        rightVolume = 0
        panning = 0
        vinFlags = 0
    }
}

// MARK: - Envelope

/// The volume ramp shared by the square and noise channels.
///
/// Four bits of volume, a direction, and a rate. It's the only amplitude
/// control a channel has, which is why every percussive Game Boy sound is a
/// fast downward envelope.
struct Envelope: Codable {
    var initialVolume = 0
    var increasing = false
    var pace = 0
    var volume = 0
    var timer = 0

    var register: UInt8 {
        UInt8(initialVolume << 4) | (increasing ? 0x08 : 0) | UInt8(pace)
    }

    /// The DAC is powered by the top five bits of this register. All zero and
    /// the channel is switched off entirely, not merely silent — which is how
    /// games mute a channel without touching NR52.
    var dacEnabled: Bool { initialVolume > 0 || increasing }

    mutating func write(_ value: UInt8) {
        initialVolume = Int(value >> 4)
        increasing = value & 0x08 != 0
        pace = Int(value & 0x07)
    }

    mutating func trigger() {
        volume = initialVolume
        timer = pace
    }

    mutating func clock() {
        guard pace > 0 else { return }
        timer -= 1
        guard timer <= 0 else { return }
        timer = pace
        if increasing {
            if volume < 15 { volume += 1 }
        } else if volume > 0 {
            volume -= 1
        }
    }
}

// MARK: - Square

/// Channels 1 and 2. Identical but for the frequency sweep, which only channel
/// 1 has.
struct SquareChannel: Codable {
    /// Four duty cycles: 12.5%, 25%, 50%, 75%. The last is the same waveform as
    /// 25% with the phase inverted, so there are really only three timbres.
    static let dutyPatterns: [[UInt8]] = [
        [0, 0, 0, 0, 0, 0, 0, 1],
        [1, 0, 0, 0, 0, 0, 0, 1],
        [1, 0, 0, 0, 0, 1, 1, 1],
        [0, 1, 1, 1, 1, 1, 1, 0],
    ]

    let hasSweep: Bool

    var enabled = false
    /// Zero, not the 50%% default it might look like it wants: powering the
    /// sound hardware off has to leave every register reading as written-zero.
    var duty = 0
    var length = 0
    var lengthEnabled = false
    var frequency = 0
    var envelope = Envelope()

    private var timer = 0
    private var phase = 0

    // Sweep state, unused on channel 2.
    private var sweepPace = 0
    private var sweepDown = false
    private var sweepShift = 0
    private var sweepTimer = 0
    private var sweepShadow = 0
    private var sweepActive = false

    init(hasSweep: Bool) {
        self.hasSweep = hasSweep
    }

    var dutyRegister: UInt8 { UInt8(duty << 6) }

    var sweepRegister: UInt8 {
        get { UInt8(sweepPace << 4) | (sweepDown ? 0x08 : 0) | UInt8(sweepShift) }
        set {
            sweepPace = Int((newValue >> 4) & 0x07)
            sweepDown = newValue & 0x08 != 0
            sweepShift = Int(newValue & 0x07)
        }
    }

    mutating func step(_ clocks: Int) {
        timer -= clocks
        // A period of zero would spin forever; the guard costs nothing and the
        // frequency registers are writable to values that produce one.
        let period = max((2048 - frequency) * 4, 1)
        while timer <= 0 {
            timer += period
            phase = (phase + 1) & 7
        }
    }

    /// −1 to 1, or zero when the DAC is off.
    var dacOutput: Float {
        guard envelope.dacEnabled else { return 0 }
        guard enabled else { return -1 }
        let level = Self.dutyPatterns[duty][phase] == 1 ? envelope.volume : 0
        return Float(level) / 7.5 - 1
    }

    // MARK: Writes

    mutating func writeDuty(_ value: UInt8) {
        duty = Int(value >> 6)
        length = 64 - Int(value & 0x3F)
    }

    mutating func writeEnvelope(_ value: UInt8) {
        envelope.write(value)
        // Switching the DAC off kills the channel immediately.
        if !envelope.dacEnabled { enabled = false }
    }

    mutating func writeFrequencyLow(_ value: UInt8) {
        frequency = (frequency & 0x0700) | Int(value)
    }

    mutating func writeControl(_ value: UInt8, extraLengthClock: Bool) {
        frequency = (frequency & 0x00FF) | (Int(value & 0x07) << 8)

        let wasEnabled = lengthEnabled
        lengthEnabled = value & 0x40 != 0

        // Enabling the length counter in the half of the frame-sequencer cycle
        // that doesn't clock lengths costs one extra tick. Obscure, and audible
        // as a note held one step too long in the games that rely on it.
        if !wasEnabled && lengthEnabled && !extraLengthClock && length > 0 {
            length -= 1
            if length == 0 { enabled = false }
        }

        if value & 0x80 != 0 { trigger() }
    }

    private mutating func trigger() {
        enabled = envelope.dacEnabled
        if length == 0 { length = 64 }
        timer = max((2048 - frequency) * 4, 1)
        envelope.trigger()

        guard hasSweep else { return }
        sweepShadow = frequency
        sweepTimer = sweepPace == 0 ? 8 : sweepPace
        sweepActive = sweepPace > 0 || sweepShift > 0
        // The overflow check runs on trigger as well as on each sweep step, so
        // a channel can switch itself off before producing a single sample.
        if sweepShift > 0 { _ = nextSweepFrequency() }
    }

    // MARK: Clocking

    mutating func clockLength() {
        guard lengthEnabled, length > 0 else { return }
        length -= 1
        if length == 0 { enabled = false }
    }

    mutating func clockSweep() {
        guard hasSweep else { return }
        sweepTimer -= 1
        guard sweepTimer <= 0 else { return }

        sweepTimer = sweepPace == 0 ? 8 : sweepPace
        guard sweepActive, sweepPace > 0 else { return }

        let next = nextSweepFrequency()
        guard next <= 2047, sweepShift > 0 else { return }
        sweepShadow = next
        frequency = next
        // Calculated a second time purely for the overflow check, whose result
        // is discarded. That really is what the hardware does.
        _ = nextSweepFrequency()
    }

    private mutating func nextSweepFrequency() -> Int {
        let delta = sweepShadow >> sweepShift
        let next = sweepDown ? sweepShadow - delta : sweepShadow + delta
        if next > 2047 { enabled = false }
        return next
    }
}

// MARK: - Wave

/// Channel 3: thirty-two four-bit samples read from memory in a loop.
///
/// The only channel a game can give an arbitrary timbre, and the only one whose
/// volume control is a shift rather than a multiply — so it has four settings,
/// one of which is silence.
struct WaveChannel: Codable {
    var enabled = false
    var dacEnabled = false
    var length = 0
    var lengthEnabled = false
    var frequency = 0
    var volumeCode = 0
    /// Sixteen bytes, two samples each.
    var waveRAM = [UInt8](repeating: 0, count: 16)

    private var timer = 0
    private var position = 0

    /// 0 mutes; the rest are full, half and quarter volume.
    private static let volumeShifts = [4, 0, 1, 2]

    mutating func step(_ clocks: Int) {
        timer -= clocks
        // Twice the rate of the square channels, because there are 32 samples
        // per cycle rather than 8.
        let period = max((2048 - frequency) * 2, 1)
        while timer <= 0 {
            timer += period
            position = (position + 1) & 31
        }
    }

    var dacOutput: Float {
        guard dacEnabled else { return 0 }
        guard enabled else { return -1 }
        let byte = waveRAM[position >> 1]
        let nibble = position & 1 == 0 ? byte >> 4 : byte & 0x0F
        return Float(nibble >> Self.volumeShifts[volumeCode]) / 7.5 - 1
    }

    mutating func writeDACEnable(_ value: UInt8) {
        dacEnabled = value & 0x80 != 0
        if !dacEnabled { enabled = false }
    }

    /// Eight bits rather than six: this channel counts to 256.
    mutating func writeLength(_ value: UInt8) {
        length = 256 - Int(value)
    }

    mutating func writeFrequencyLow(_ value: UInt8) {
        frequency = (frequency & 0x0700) | Int(value)
    }

    mutating func writeControl(_ value: UInt8, extraLengthClock: Bool) {
        frequency = (frequency & 0x00FF) | (Int(value & 0x07) << 8)

        let wasEnabled = lengthEnabled
        lengthEnabled = value & 0x40 != 0
        if !wasEnabled && lengthEnabled && !extraLengthClock && length > 0 {
            length -= 1
            if length == 0 { enabled = false }
        }

        if value & 0x80 != 0 {
            enabled = dacEnabled
            if length == 0 { length = 256 }
            timer = max((2048 - frequency) * 2, 1)
            position = 0
        }
    }

    mutating func clockLength() {
        guard lengthEnabled, length > 0 else { return }
        length -= 1
        if length == 0 { enabled = false }
    }
}

// MARK: - Noise

/// Channel 4: a shift register tapped to produce pseudo-random bits.
///
/// Fifteen bits normally, or seven in the narrow mode, which shortens the
/// sequence enough that it stops sounding like noise and starts sounding like a
/// metallic tone. Every drum in every Game Boy game is this channel.
struct NoiseChannel: Codable {
    var enabled = false
    var length = 0
    var lengthEnabled = false
    var envelope = Envelope()

    private var lfsr: UInt16 = 0x7FFF
    private var clockShift = 0
    private var narrow = false
    private var divisorCode = 0
    private var timer = 0

    /// Divisor 0 is a half-step, not a zero — the table starts at 8, not 0.
    private static let divisors = [8, 16, 32, 48, 64, 80, 96, 112]

    var polynomialRegister: UInt8 {
        get { UInt8(clockShift << 4) | (narrow ? 0x08 : 0) | UInt8(divisorCode) }
        set {
            clockShift = Int(newValue >> 4)
            narrow = newValue & 0x08 != 0
            divisorCode = Int(newValue & 0x07)
        }
    }

    mutating func step(_ clocks: Int) {
        timer -= clocks
        let period = max(Self.divisors[divisorCode] << clockShift, 1)
        while timer <= 0 {
            timer += period
            advanceShiftRegister()
        }
    }

    private mutating func advanceShiftRegister() {
        // XOR of the low two bits feeds back into the top.
        let feedback = (lfsr ^ (lfsr >> 1)) & 1
        lfsr >>= 1
        lfsr |= feedback << 14
        if narrow {
            // The same bit is also written to bit 6, which is what shortens the
            // sequence from 32,767 steps to 127.
            lfsr = (lfsr & ~0x0040) | (feedback << 6)
        }
    }

    var dacOutput: Float {
        guard envelope.dacEnabled else { return 0 }
        guard enabled else { return -1 }
        // Inverted: a zero in the register means output.
        let level = lfsr & 1 == 0 ? envelope.volume : 0
        return Float(level) / 7.5 - 1
    }

    mutating func writeLength(_ value: UInt8) {
        length = 64 - Int(value & 0x3F)
    }

    mutating func writeEnvelope(_ value: UInt8) {
        envelope.write(value)
        if !envelope.dacEnabled { enabled = false }
    }

    mutating func writeControl(_ value: UInt8, extraLengthClock: Bool) {
        let wasEnabled = lengthEnabled
        lengthEnabled = value & 0x40 != 0
        if !wasEnabled && lengthEnabled && !extraLengthClock && length > 0 {
            length -= 1
            if length == 0 { enabled = false }
        }

        if value & 0x80 != 0 {
            enabled = envelope.dacEnabled
            if length == 0 { length = 64 }
            timer = max(Self.divisors[divisorCode] << clockShift, 1)
            // Every bit set, so the first output is silence rather than a click.
            lfsr = 0x7FFF
            envelope.trigger()
        }
    }

    mutating func clockLength() {
        guard lengthEnabled, length > 0 else { return }
        length -= 1
        if length == 0 { enabled = false }
    }
}

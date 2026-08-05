//
//  SystemTimer.swift
//  GameBoyKit
//

import Foundation

/// The divider and the programmable timer.
///
/// Both are views onto a single 16-bit counter that runs at the system clock and
/// is never stopped. `DIV` is simply its top byte, and `TIMA` increments on the
/// **falling edge** of one selected bit of it.
///
/// Modelling it that way rather than as "add one every N cycles" is what makes
/// the famous edge cases fall out for free: writing to `DIV` resets the whole
/// counter, and if the selected bit happened to be high at that moment, the
/// reset drives it low and `TIMA` increments as a side effect of a write that
/// looks unrelated.
///
/// Named `SystemTimer` rather than `Timer` because the kit compiles into the
/// same module as the SwiftUI shell, where `Timer` already means something.
final class SystemTimer: Codable {
    /// The full counter. `DIV` at 0xFF04 is its high byte.
    private(set) var counter: UInt16 = 0
    var tima: UInt8 = 0
    var modulo: UInt8 = 0
    var control: UInt8 = 0

    /// Overflow doesn't reload immediately — `TIMA` reads back as zero for four
    /// clocks first, and a write during that window cancels the reload. Games
    /// don't rely on this, but the timing test ROMs check it precisely.
    private var reloadDelay = 0
    private var lastEdgeInput = false

    var divider: UInt8 { UInt8(counter >> 8) }

    /// Which bit of the counter drives the timer, per the two low bits of `TAC`.
    ///
    /// Note that 00 is the *slowest* setting and sits at bit 9, out of order
    /// with the other three — an artefact of the hardware, not a mistake.
    private var selectedBit: UInt16 {
        switch control & 0x03 {
        case 0: 1 << 9
        case 1: 1 << 3
        case 2: 1 << 5
        default: 1 << 7
        }
    }

    private var enabled: Bool { control & 0x04 != 0 }

    // MARK: - Stepping

    /// Advances by `cycles` clocks, returning true if the timer interrupt fired.
    ///
    /// Stepped one clock at a time because the fastest setting toggles its bit
    /// every eight clocks, and batching would step straight over edges.
    func step(_ cycles: Int) -> Bool {
        var interrupted = false
        for _ in 0..<cycles {
            if reloadDelay > 0 {
                reloadDelay -= 1
                if reloadDelay == 0 {
                    tima = modulo
                    interrupted = true
                }
            }
            counter &+= 1
            updateEdge()
        }
        return interrupted
    }

    /// Increments `TIMA` when the watched bit goes from high to low.
    ///
    /// The interrupt isn't raised here: overflow only *schedules* the reload,
    /// and the interrupt belongs to the moment the modulo actually lands.
    private func updateEdge() {
        let input = enabled && (counter & selectedBit) != 0
        defer { lastEdgeInput = input }

        guard lastEdgeInput && !input else { return }
        tima &+= 1
        if tima == 0 { reloadDelay = 4 }
    }

    // MARK: - Register access

    /// Any write to `DIV` clears the counter outright — the register is
    /// write-only in the sense that the value written is discarded.
    func writeDivider() {
        counter = 0
        updateEdge()
    }

    func writeTIMA(_ value: UInt8) {
        // Writing during the reload window aborts it, so the modulo never lands.
        if reloadDelay > 0 { reloadDelay = 0 }
        tima = value
    }

    func writeControl(_ value: UInt8) {
        control = value | 0xF8
        updateEdge()
    }
}

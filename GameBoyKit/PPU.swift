//
//  PPU.swift
//  GameBoyKit
//

import Foundation

/// The picture processing unit.
///
/// The Game Boy has no framebuffer — there isn't enough RAM for one. The PPU
/// walks the screen in step with the beam, and a line only exists for the
/// 456 clocks it takes to draw it. Everything a game does visually is timed
/// against that walk, which is why the mode timings below matter more than the
/// pixel maths does.
///
/// Rendering happens a whole scanline at a time, at the point the real hardware
/// would finish drawing it. The one thing that costs is mid-scanline register
/// changes: a handful of games wobble `SCX` during mode 3 for a water effect,
/// and here that wobble lands a line late.
final class PPU: Codable {
    static let width = 160
    static let height = 144

    /// 456 clocks a line, 154 lines including the ten spent in VBlank.
    static let clocksPerLine = 456
    static let linesPerFrame = 154
    static let clocksPerFrame = clocksPerLine * linesPerFrame

    var vram = [UInt8](repeating: 0, count: 0x2000)
    var oam = [UInt8](repeating: 0, count: 0xA0)

    // MARK: - Registers

    /// Control. Bit 7 powers the whole unit; bit 0 hides the background.
    var control: UInt8 = 0x91
    /// Only bits 3–6 are writable — the rest report the current mode and are
    /// maintained here.
    private var statusFlags: UInt8 = 0
    var scrollY: UInt8 = 0
    var scrollX: UInt8 = 0
    var line: UInt8 = 0
    var lineCompare: UInt8 = 0
    var backgroundPalette: UInt8 = 0xFC
    var objectPalette0: UInt8 = 0xFF
    var objectPalette1: UInt8 = 0xFF
    var windowY: UInt8 = 0
    var windowX: UInt8 = 0

    // MARK: - State

    private var clock = 0
    private var mode = 2
    /// The window has its own line counter that only advances on lines where
    /// the window was actually drawn. Using `LY` instead makes the window slide
    /// upward whenever a game enables it partway down the screen.
    private var windowLine = 0
    /// Level-triggered: the STAT interrupt fires on the rising edge of "any
    /// enabled condition is true", not once per condition. Games that enable
    /// two sources at once depend on the difference.
    private var statLine = false

    /// The last completed frame. Rendering goes to a second buffer so a frame
    /// is never read while it's half-drawn.
    private(set) var frontBuffer = [UInt32](repeating: Palette.dmg[0], count: width * height)
    private var backBuffer = [UInt32](repeating: Palette.dmg[0], count: width * height)
    /// Background colour indices for the line being drawn, kept because sprite
    /// priority is decided against the index rather than the final colour.
    private var backgroundIndices = [UInt8](repeating: 0, count: width)

    /// Set for one step when a frame finished, so the shell knows to present.
    private(set) var frameCompleted = false

    enum Palette {
        /// The original screen's greens, rather than grey. The hardware only
        /// ever produced four shades, so this is a colour choice, not a filter.
        static let dmg: [UInt32] = [0xFF_9BBC0F, 0xFF_8BAC0F, 0xFF_306230, 0xFF_0F380F]
    }

    // MARK: - Register access

    var status: UInt8 {
        get {
            // Bit 7 is unused and reads high.
            statusFlags | 0x80 | (line == lineCompare ? 0x04 : 0) | UInt8(mode)
        }
        set { statusFlags = newValue & 0x78 }
    }

    private var enabled: Bool { control & 0x80 != 0 }

    // MARK: - Stepping

    /// Advances the beam and returns the interrupts raised, as an `IF` mask.
    func step(_ cycles: Int) -> UInt8 {
        frameCompleted = false

        guard enabled else {
            // Switching the LCD off resets the beam to the top of the screen.
            // Games do this to get unrestricted VRAM access during a load.
            clock = 0
            line = 0
            mode = 0
            windowLine = 0
            statLine = false
            return 0
        }

        var interrupts: UInt8 = 0
        var remaining = cycles

        while remaining > 0 {
            // Step no further than the end of the current line so that mode
            // changes land on the right clock even with a long instruction.
            let chunk = min(remaining, Self.clocksPerLine - clock)
            clock += chunk
            remaining -= chunk

            if clock >= Self.clocksPerLine {
                clock = 0
                line = line >= UInt8(Self.linesPerFrame - 1) ? 0 : line + 1
                if line == 0 { windowLine = 0 }
            }

            interrupts |= updateMode()
        }

        return interrupts
    }

    /// Works out which mode the current clock falls in, and does the work that
    /// belongs to entering it.
    private func updateMode() -> UInt8 {
        var interrupts: UInt8 = 0
        let previous = mode

        if line >= UInt8(Self.height) {
            mode = 1
        } else {
            switch clock {
            case 0..<80: mode = 2                       // scanning OAM
            case 80..<252: mode = 3                     // drawing
            default: mode = 0                           // horizontal blank
            }
        }

        if mode != previous {
            switch mode {
            case 0:
                // Drawing has finished, so the line is now settled.
                renderLine()
            case 1:
                // Entering VBlank completes the frame.
                swap(&frontBuffer, &backBuffer)
                frameCompleted = true
                interrupts |= Interrupt.vblank.rawValue
            default:
                break
            }
        }

        // Recomputed every step rather than only on mode changes, because LYC
        // can be written at any moment and its match is one of the conditions.
        let condition =
            (mode == 0 && statusFlags & 0x08 != 0)
            || (mode == 1 && statusFlags & 0x10 != 0)
            || (mode == 2 && statusFlags & 0x20 != 0)
            || (line == lineCompare && statusFlags & 0x40 != 0)

        if condition && !statLine { interrupts |= Interrupt.lcdStatus.rawValue }
        statLine = condition

        return interrupts
    }

    // MARK: - Rendering

    private func renderLine() {
        let y = Int(line)
        guard y < Self.height else { return }

        if control & 0x01 != 0 {
            renderBackground(y)
        } else {
            // Bit 0 blanks the background entirely, and blanks it to colour 0
            // rather than to whatever the palette maps colour 0 to.
            let start = y * Self.width
            for x in 0..<Self.width {
                backBuffer[start + x] = Palette.dmg[0]
                backgroundIndices[x] = 0
            }
        }

        if control & 0x02 != 0 { renderSprites(y) }
    }

    private func renderBackground(_ y: Int) {
        let backgroundMap = control & 0x08 != 0 ? 0x1C00 : 0x1800
        let windowMap = control & 0x40 != 0 ? 0x1C00 : 0x1800
        // Bit 4 picks between two tile blocks, and the second is addressed with
        // a *signed* index from 0x9000 — a way of fitting 384 tiles into a
        // space that only has room for 256 indices.
        let signedIndices = control & 0x10 == 0

        let windowVisible = control & 0x20 != 0 && y >= Int(windowY)
        var windowDrawn = false
        let rowStart = y * Self.width

        for x in 0..<Self.width {
            let map: Int, tileX: Int, tileY: Int

            // WX is offset by seven, so a window flush against the left edge is
            // written as 7 and values below that push it off-screen.
            if windowVisible && x + 7 >= Int(windowX) {
                windowDrawn = true
                map = windowMap
                tileX = x + 7 - Int(windowX)
                tileY = windowLine
            } else {
                map = backgroundMap
                // The background wraps at 256 pixels in both directions.
                tileX = (x + Int(scrollX)) & 0xFF
                tileY = (y + Int(scrollY)) & 0xFF
            }

            let index = vram[map + (tileY >> 3) * 32 + (tileX >> 3)]
            let tile = signedIndices
                ? 0x1000 + Int(Int8(bitPattern: index)) * 16
                : Int(index) * 16

            let row = tile + (tileY & 7) * 2
            let bit = UInt8(7 - (tileX & 7))
            // Two bitplanes, one byte each, with the two bits of a pixel split
            // across them at the same position.
            let colour = ((vram[row + 1] >> bit) & 1) << 1 | ((vram[row] >> bit) & 1)

            backgroundIndices[x] = colour
            backBuffer[rowStart + x] = shade(colour, through: backgroundPalette)
        }

        if windowDrawn { windowLine += 1 }
    }

    private func renderSprites(_ y: Int) {
        let tall = control & 0x04 != 0
        let spriteHeight = tall ? 16 : 8

        // Ten per line, taken in OAM order — the eleventh is dropped no matter
        // how important it is. Flicker in crowded games is this limit, not a
        // slowdown.
        var visible: [(x: Int, oamIndex: Int)] = []
        visible.reserveCapacity(10)
        for index in stride(from: 0, to: oam.count, by: 4) {
            let top = Int(oam[index]) - 16
            guard y >= top && y < top + spriteHeight else { continue }
            visible.append((Int(oam[index + 1]) - 8, index))
            if visible.count == 10 { break }
        }

        // On the monochrome hardware the leftmost sprite wins, with OAM order
        // breaking ties. Drawing lowest-priority first and letting the rest
        // paint over it gets the same result as an explicit priority test.
        visible.sort { $0.x != $1.x ? $0.x > $1.x : $0.oamIndex > $1.oamIndex }

        let rowStart = y * Self.width

        for sprite in visible {
            let attributes = oam[sprite.oamIndex + 3]
            let top = Int(oam[sprite.oamIndex]) - 16

            // In 8×16 mode the low bit of the tile number is ignored, so the
            // pair is always aligned.
            var tile = Int(oam[sprite.oamIndex + 2])
            if tall { tile &= 0xFE }

            var row = y - top
            if attributes & 0x40 != 0 { row = spriteHeight - 1 - row }

            let address = tile * 16 + row * 2
            let low = vram[address]
            let high = vram[address + 1]
            let palette = attributes & 0x10 != 0 ? objectPalette1 : objectPalette0
            let behindBackground = attributes & 0x80 != 0
            let flipX = attributes & 0x20 != 0

            for pixel in 0..<8 {
                let x = sprite.x + pixel
                guard x >= 0 && x < Self.width else { continue }

                let bit = UInt8(flipX ? pixel : 7 - pixel)
                let colour = ((high >> bit) & 1) << 1 | ((low >> bit) & 1)
                // Colour 0 is transparent for sprites — which is why sprite
                // palettes only ever define three usable shades.
                guard colour != 0 else { continue }
                if behindBackground && backgroundIndices[x] != 0 { continue }

                backBuffer[rowStart + x] = shade(colour, through: palette)
            }
        }
    }

    /// Palette registers are four two-bit fields: the colour index selects the
    /// field, and the field selects the shade.
    @inline(__always)
    private func shade(_ colour: UInt8, through palette: UInt8) -> UInt32 {
        Palette.dmg[Int((palette >> (colour * 2)) & 0x03)]
    }
}

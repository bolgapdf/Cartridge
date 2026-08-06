//
//  Thumbstick.swift
//  Cartridge
//

#if os(iOS)
import SwiftUI

/// A stick that drives the d-pad.
///
/// The Game Boy's d-pad is four switches, and two can be closed at once — so
/// diagonals are real input, not an approximation. A stick maps onto that
/// directly: take the displacement, drop it into one of eight sectors, and hold
/// the one or two switches that sector means.
///
/// The reason to prefer it on glass is that a d-pad asks your thumb to find a
/// specific place and stay there, with no edges to feel for. A stick asks only
/// for a direction.
struct Thumbstick: View {
    let emulator: Emulator

    /// How far the thumb must move before any direction registers. Without it,
    /// a thumb resting dead centre jitters between directions on noise alone.
    private let deadZone: CGFloat = 0.28
    /// How far past a sector boundary the thumb must travel before the
    /// direction changes. Holding exactly on a boundary otherwise flickers
    /// between two directions several times a second, which reads on screen as
    /// the character shaking in place.
    private let boundarySlack = CGFloat.pi / 18      // 10°

    private let radius: CGFloat = 62
    private let knobRadius: CGFloat = 30

    @State private var offset: CGSize = .zero
    @State private var held: Set<ConsoleButton> = []
    @State private var sector: Int?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.14))
                .overlay(Circle().strokeBorder(.white.opacity(0.06)))

            Circle()
                .fill(Color(white: held.isEmpty ? 0.26 : 0.34))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .offset(offset)
                .animation(.interactiveSpring(duration: 0.12), value: offset)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in update(to: value.translation) }
                .onEnded { _ in release() }
        )
        .accessibilityLabel("Direction pad")
    }

    // MARK: - Mapping

    private func update(to translation: CGSize) {
        // The knob is clamped to the well, but the *direction* comes from the
        // raw translation — so sliding a thumb past the edge keeps steering
        // rather than sticking at whatever it last touched.
        let limit = radius - knobRadius
        let distance = hypot(translation.width, translation.height)
        let clamped = distance > limit ? limit / distance : 1
        offset = CGSize(width: translation.width * clamped, height: translation.height * clamped)

        guard distance / limit > deadZone else {
            sector = nil
            setHeld([])
            return
        }

        // Screen coordinates put y downward, which is also the direction the
        // console calls "down", so no flip is needed.
        let angle = atan2(translation.height, translation.width)
        let next = settledSector(for: angle)
        sector = next
        setHeld(directions(for: next))
    }

    /// Which of eight 45° sectors the thumb is in, refusing to leave the
    /// current one until it's clearly outside.
    private func settledSector(for angle: CGFloat) -> Int {
        let raw = Int(((angle + .pi) / (.pi / 4)).rounded()) % 8
        guard let current = sector, raw != current else { return raw }

        let centre = CGFloat(current) * (.pi / 4) - .pi
        var delta = abs(angle - centre)
        if delta > .pi { delta = 2 * .pi - delta }

        // Still within half a sector plus the slack: stay where we are.
        return delta < (.pi / 8) + boundarySlack ? current : raw
    }

    private func directions(for sector: Int) -> Set<ConsoleButton> {
        switch sector {
        case 0: return [.left]
        case 1: return [.left, .up]
        case 2: return [.up]
        case 3: return [.right, .up]
        case 4: return [.right]
        case 5: return [.right, .down]
        case 6: return [.down]
        default: return [.left, .down]
        }
    }

    private func setHeld(_ wanted: Set<ConsoleButton>) {
        guard wanted != held else { return }

        for button in held.subtracting(wanted) {
            emulator.set(button, pressed: false)
        }
        for button in wanted.subtracting(held) {
            emulator.set(button, pressed: true)
            // Only on the way in, and only for a new direction — one tap of
            // feedback per change, not a buzz for every frame of a drag.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        held = wanted
    }

    private func release() {
        offset = .zero
        sector = nil
        setHeld([])
    }
}
#endif

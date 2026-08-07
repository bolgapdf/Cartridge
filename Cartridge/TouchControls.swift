//
//  TouchControls.swift
//  Cartridge
//

#if os(iOS)
import SwiftUI

/// The colours the hardware used.
///
/// The DMG's buttons weren't grey — the d-pad was near-black, A and B were a
/// deep magenta, and start and select were pale slabs set at an angle. Matching
/// that is worth more than any amount of neutral styling: it makes the controls
/// legible at a glance, because the shapes and colours already mean something.
private enum ControlStyle {
    static let pad = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let padPressed = Color(red: 0.26, green: 0.26, blue: 0.30)
    static let face = Color(red: 0.60, green: 0.13, blue: 0.32)
    static let facePressed = Color(red: 0.76, green: 0.20, blue: 0.42)
    static let pill = Color(red: 0.42, green: 0.42, blue: 0.47)
    static let pillPressed = Color(red: 0.58, green: 0.58, blue: 0.63)
    static let well = Color(red: 0.09, green: 0.09, blue: 0.11)

    /// A highlight along the top edge and a shadow underneath, which is all it
    /// takes to read as a physical button rather than a coloured rectangle.
    static func relief(_ pressed: Bool) -> LinearGradient {
        LinearGradient(
            colors: [.white.opacity(pressed ? 0.04 : 0.22), .clear, .black.opacity(0.22)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// On-screen controls, laid out the way the hardware was.
///
/// Split into halves so the same pieces can sit under the screen in portrait or
/// flank it in landscape. Landscape is the one that matters on a phone — it's
/// the only way to get a 160×144 screen large enough to read without pushing
/// the buttons somewhere your thumbs aren't.
struct TouchControls: View {
    enum Half { case left, right, both }

    let emulator: Emulator
    let half: Half
    /// A stick or the original cross. Some games — anything needing a single
    /// exact direction, like a menu — are easier on the cross, so both stay.
    @AppStorage("useThumbstick") private var useThumbstick = true

    @ViewBuilder
    private var directions: some View {
        if useThumbstick {
            Thumbstick(emulator: emulator)
        } else {
            DirectionalPad(emulator: emulator)
        }
    }

    var body: some View {
        switch half {
        case .left:
            directions
                .padding(.horizontal, 18)

        case .right:
            VStack(spacing: 18) {
                FaceButtons(emulator: emulator)
                PillButton(title: "START", button: .start, emulator: emulator)
                PillButton(title: "SELECT", button: .select, emulator: emulator)
            }
            .padding(.horizontal, 18)

        case .both:
            VStack(spacing: 18) {
                HStack(alignment: .center) {
                    directions
                    Spacer(minLength: 24)
                    FaceButtons(emulator: emulator)
                }
                HStack(spacing: 28) {
                    PillButton(title: "SELECT", button: .select, emulator: emulator)
                    PillButton(title: "START", button: .start, emulator: emulator)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Pieces

private struct DirectionalPad: View {
    let emulator: Emulator
    private let size: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            arm(.up, "chevron.up")
            HStack(spacing: 0) {
                arm(.left, "chevron.left")
                ZStack {
                    Rectangle().fill(ControlStyle.pad)
                    Circle()
                        .fill(.black.opacity(0.25))
                        .frame(width: 14, height: 14)
                }
                .frame(width: size, height: size)
                arm(.right, "chevron.right")
            }
            arm(.down, "chevron.down")
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func arm(_ button: ConsoleButton, _ symbol: String) -> some View {
        PressableSurface(button: button, emulator: emulator) { isDown in
            ZStack {
                Rectangle().fill(isDown ? ControlStyle.padPressed : ControlStyle.pad)
                ControlStyle.relief(isDown)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: size, height: size)
        }
    }
}

private struct FaceButtons: View {
    let emulator: Emulator

    var body: some View {
        // Offset, because A and B sit on a diagonal rather than side by side.
        HStack(spacing: 18) {
            round(.b, "B").offset(y: 16)
            round(.a, "A")
        }
    }

    private func round(_ button: ConsoleButton, _ label: String) -> some View {
        PressableSurface(button: button, emulator: emulator) { isDown in
            ZStack {
                Circle().fill(isDown ? ControlStyle.facePressed : ControlStyle.face)
                Circle().fill(ControlStyle.relief(isDown))
                Circle().strokeBorder(.black.opacity(0.28), lineWidth: 1)
                Text(label)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.45), radius: isDown ? 1 : 4, y: isDown ? 0 : 2)
        }
    }
}

private struct PillButton: View {
    let title: String
    let button: ConsoleButton
    let emulator: Emulator

    var body: some View {
        PressableSurface(button: button, emulator: emulator) { isDown in
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 17)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(isDown ? ControlStyle.pillPressed : ControlStyle.pill)
                        .overlay(Capsule().fill(ControlStyle.relief(isDown)))
                }
                // Set at an angle, as they were on the hardware.
                .rotationEffect(.degrees(-12))
        }
    }
}

/// Turns any view into a press-and-hold control wired to one console button.
///
/// A zero-distance drag rather than a `Button`, for two reasons: a tap gesture
/// only fires on release, and this way sliding a thumb from left to up on the
/// d-pad releases one direction and presses the other without lifting — which
/// is how anyone who played the original expects a d-pad to behave.
private struct PressableSurface<Content: View>: View {
    let button: ConsoleButton
    let emulator: Emulator
    @ViewBuilder let content: (Bool) -> Content

    @State private var isDown = false

    var body: some View {
        content(isDown)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // The gesture fires continuously; only the transition
                        // is worth sending, and only the transition should
                        // trigger haptic feedback.
                        guard !isDown else { return }
                        isDown = true
                        emulator.set(button, pressed: true)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        // A tap fast enough can end without `onChanged` ever
                        // having run, and then the press was never sent at all.
                        // The emulator holds every press for a few frames, so
                        // pressing here and releasing immediately still lands.
                        if !isDown { emulator.set(button, pressed: true) }
                        isDown = false
                        emulator.set(button, pressed: false)
                    }
            )
            .accessibilityLabel(button.label)
            .accessibilityAddTraits(.isButton)
    }
}
#endif

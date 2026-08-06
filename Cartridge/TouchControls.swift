//
//  TouchControls.swift
//  Cartridge
//

#if os(iOS)
import SwiftUI

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

    var body: some View {
        switch half {
        case .left:
            DirectionalPad(emulator: emulator)
                .padding(.horizontal, 18)

        case .right:
            VStack(spacing: 22) {
                FaceButtons(emulator: emulator)
                PillButton(title: "START", button: .start, emulator: emulator)
                PillButton(title: "SELECT", button: .select, emulator: emulator)
            }
            .padding(.horizontal, 18)

        case .both:
            VStack(spacing: 18) {
                HStack(alignment: .center) {
                    DirectionalPad(emulator: emulator)
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
                Rectangle()
                    .fill(Color(white: 0.16))
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
                Rectangle().fill(Color(white: isDown ? 0.34 : 0.16))
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
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
                Circle().fill(Color(white: isDown ? 0.42 : 0.22))
                Text(label)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 62, height: 62)
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
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Color(white: isDown ? 0.36 : 0.18), in: Capsule())
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

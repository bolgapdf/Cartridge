//
//  PlayerView.swift
//  Cartridge
//

import SwiftUI

/// A game, running.
///
/// The layout turns over between orientations rather than scaling: upright, the
/// screen sits above the controls the way the hardware did; on its side, the
/// controls move to either edge so the screen can take the full height. Keeping
/// one layout for both would mean either a tiny screen or unreachable buttons.
struct PlayerView: View {
    let emulator: Emulator
    let close: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInterrupted = false

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        #endif
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .up], action: handleKey)
        .onChange(of: scenePhase, handleScenePhase)
        .onDisappear {
            // Leaving the screen has to write the save, record the time and
            // capture the tile — the same work pausing does.
            emulator.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        if isLandscape {
            HStack(spacing: 0) {
                TouchControls(emulator: emulator, half: .left)
                GameScreen(emulator: emulator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TouchControls(emulator: emulator, half: .right)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            VStack(spacing: 0) {
                GameScreen(emulator: emulator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TouchControls(emulator: emulator, half: .both)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        #else
        GameScreen(emulator: emulator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Library", systemImage: "chevron.left", action: close)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(
                emulator.isRunning ? "Pause" : "Resume",
                systemImage: emulator.isRunning ? "pause.fill" : "play.fill"
            ) {
                emulator.togglePause()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis.circle") {
                Picker("Speed", selection: Binding(
                    get: { emulator.speed },
                    set: { emulator.speed = $0 }
                )) {
                    ForEach(Emulator.Speed.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Divider()
                ForEach(1...3, id: \.self) { slot in
                    Button("Save to Slot \(slot)", systemImage: "square.and.arrow.down") {
                        emulator.saveState(slot: slot)
                    }
                }
                Divider()
                ForEach(1...3, id: \.self) { slot in
                    Button("Load Slot \(slot)", systemImage: "square.and.arrow.up") {
                        emulator.loadState(slot: slot)
                    }
                    .disabled(!emulator.hasState(slot: slot))
                }
                Divider()
                Button("Reset", systemImage: "arrow.counterclockwise") { emulator.reset() }
            }
        }
    }

    // MARK: - Input

    private func handleScenePhase(_ old: ScenePhase, _ phase: ScenePhase) {
        switch phase {
        case .active:
            // Only resume what the system interrupted, so a game deliberately
            // paused stays paused.
            if wasInterrupted { emulator.start() }
            wasInterrupted = false

        case .background:
            wasInterrupted = emulator.isRunning
            emulator.pause()

        default:
            // `.inactive` means different things per platform. On iOS it's the
            // app switcher or a notification being pulled down, and stopping is
            // right. On the Mac it only means another window took focus, and a
            // game that halts every time you glance elsewhere is unusable.
            #if os(iOS)
            wasInterrupted = emulator.isRunning
            emulator.pause()
            #endif
        }
    }

    /// One keyboard layout for both platforms — an iPad with a keyboard is as
    /// good a way to play as a Mac.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let pressed = press.phase == .down

        if press.key == .space {
            emulator.isBoosting = pressed
            return .handled
        }

        let button: ConsoleButton?
        switch press.key {
        case .upArrow: button = .up
        case .downArrow: button = .down
        case .leftArrow: button = .left
        case .rightArrow: button = .right
        case .return: button = .start
        case .tab: button = .select
        default:
            switch press.characters.lowercased() {
            case "x": button = .a
            case "z": button = .b
            default: button = nil
            }
        }

        guard let button else { return .ignored }
        emulator.set(button, pressed: pressed)
        return .handled
    }
}

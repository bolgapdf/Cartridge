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
    @State private var sharedClip: ClipExport?
    @State private var isConfirmingExit = false
    @ThemeSetting private var theme
    @AppStorage("autoResume") private var autoResume = true
    #if os(iOS)
    @AppStorage("useThumbstick") private var useThumbstick = true
    #endif

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    #endif

    var body: some View {
        ZStack {
            // The player is the console body, so it wears the same shell as the
            // shelf it was opened from. It used to be black regardless, which
            // made choosing a light theme feel like the setting only half
            // applied.
            theme.shell.gradient.ignoresSafeArea()
            content
        }
        .preferredColorScheme(theme.shell.scheme)
        #if os(iOS)
        // No navigation bar. It cost a strip of height the screen wanted, put a
        // second back chevron next to the one below, and none of a game's
        // controls belong in a navigation bar anyway.
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        #else
        .toolbar { macToolbar }
        #endif
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .up], action: handleKey)
        .onChange(of: scenePhase, handleScenePhase)
        .onDisappear {
            // Leaving has to write the save, record the time and capture the
            // tile — the same work pausing does.
            emulator.stop()
        }
        #if os(iOS)
        .sheet(item: $sharedClip) { clip in
            ShareSheet(items: [clip.url])
        }
        #endif
        // Leaving is one tap from the corner of the screen, next to nothing
        // else, and it ends the session. Worth asking.
        .confirmationDialog(
            "Leave \(emulator.title ?? "this game")?",
            isPresented: $isConfirmingExit,
            titleVisibility: .visible
        ) {
            Button("Leave Game", role: autoResume ? nil : .destructive) { close() }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text(autoResume
                 ? "Where you are is saved automatically, and you'll come back to this exact spot."
                 : "The game will start from the title screen next time. Anything since your last in-game save will be lost.")
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        if isLandscape {
            HStack(spacing: 0) {
                TouchControls(emulator: emulator, half: .left)
                screen.frame(maxHeight: .infinity)
                TouchControls(emulator: emulator, half: .right)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            // Nowhere else for these to go when the screen owns the full
            // height, so they take a thin strip off the top.
            .safeAreaInset(edge: .top) { utilityStrip }
        } else {
            // The picture goes hard against the top and the pad floats in the
            // space underneath rather than sitting on the bottom edge — held in
            // one hand, buttons at the very bottom are a stretch.
            VStack(spacing: 0) {
                screen.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                TouchControls(emulator: emulator, half: .both)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
                utilityStrip
            }
        }
        #else
        screen.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// The picture, sized by SwiftUI rather than by the view it wraps.
    ///
    /// A representable reports whatever size the wrapped `UIView`/`NSView`
    /// thinks it is, which for a plain one is close to nothing — so
    /// `maxHeight: .infinity` collapsed to an 80-point strip and the layout
    /// floated in a field of black. The console's ratio is a known constant, so
    /// stating it here takes the question away from UIKit entirely.
    private var screen: some View {
        GameScreen(emulator: emulator, surround: theme.shell.bezel)
            .aspectRatio(
                CGFloat(GameBoy.screenSize.width) / CGFloat(GameBoy.screenSize.height),
                contentMode: .fit
            )
            // A frame around the glass, as every handheld had. On a light shell
            // it's what keeps a small bright screen from being washed out by
            // the body around it, and it gives the letterboxing a home.
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.shell.bezel)
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            }
            .padding(.horizontal, 6)
    }

    // MARK: - Controls

    #if os(iOS)
    /// Back, pause and the menu. Small and out of the way — in portrait they
    /// sit at the very bottom, below the pad, because the top of the screen is
    /// worth more to the picture than it is to three buttons.
    private var utilityStrip: some View {
        HStack(spacing: 14) {
            controlButton("chevron.left", label: "Library") { isConfirmingExit = true }

            Spacer(minLength: 0)

            if !emulator.isRunning {
                Text("PAUSED")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
            }

            controlButton(
                emulator.isRunning ? "pause.fill" : "play.fill",
                label: emulator.isRunning ? "Pause" : "Resume"
            ) {
                emulator.togglePause()
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func controlButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    #endif

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        // The Mac had no way out of a game at all. The back button lives in the
        // phone's floating strip, and moving the player out of the navigation
        // stack took away the one the system had been providing — so opening a
        // game on the Mac was a one-way door.
        ToolbarItem(placement: .navigation) {
            Button("Library", systemImage: "chevron.left") { isConfirmingExit = true }
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
            Menu("More", systemImage: "ellipsis.circle") { menuItems }
        }
    }
    #endif

    /// Shared by the Mac's toolbar menu and the phone's floating one.
    @ViewBuilder
    private var menuItems: some View {
        Picker("Speed", selection: Binding(
            get: { emulator.speed },
            set: { emulator.speed = $0 }
        )) {
            ForEach(Emulator.Speed.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)

        if emulator.entry?.supportsColor == true {
            Toggle("Game Boy Color", isOn: Binding(
                get: { emulator.prefersColor },
                set: { emulator.prefersColor = $0 }
            ))
        }

        // A monochrome palette has nothing to say about a game choosing its own
        // colours, so it only appears when one is in use.
        if !emulator.isColorRunning {
            Picker("Screen", selection: Binding(
                get: { emulator.palette },
                set: { emulator.palette = $0 }
            )) {
                ForEach(ScreenPalette.all) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
        }

        Toggle("LCD Ghosting", isOn: Binding(
            get: { emulator.ghosting },
            set: { emulator.ghosting = $0 }
        ))

        #if os(iOS)
        Toggle("Thumbstick", isOn: $useThumbstick)
        #endif

        Divider()
        Button("Save Last 6 Seconds", systemImage: "film") { exportClip() }
            .disabled(!emulator.canSaveClip)
        Button("Save Screenshot", systemImage: "camera") { exportScreenshot() }

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

    // MARK: - Saving pictures

    /// Written to a temporary file and handed to the share sheet rather than
    /// straight into Photos: a clip of a game is more often going to someone
    /// than into a camera roll, and this way the choice stays open.
    private func exportClip() {
        guard let data = emulator.makeClip() else { return }
        let name = (emulator.title ?? "Cartridge").replacingOccurrences(of: "/", with: "_")
        save(data, named: "\(name).gif")
    }

    private func exportScreenshot() {
        guard let image = emulator.makeScreenshot(),
              let data = FrameImage.png(from: image) else { return }
        let name = (emulator.title ?? "Cartridge").replacingOccurrences(of: "/", with: "_")
        save(data, named: "\(name).png")
    }

    private func save(_ data: Data, named name: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        #if os(iOS)
        sharedClip = ClipExport(url: url)
        #else
        // On the Mac there's a Finder to drop it into, so it goes to Downloads
        // and reveals itself rather than opening a share sheet nobody asked for.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = downloads.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: url, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        #endif
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

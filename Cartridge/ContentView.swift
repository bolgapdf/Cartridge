//
//  ContentView.swift
//  Cartridge
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var emulator = Emulator()
    @State private var isImporting = false
    @State private var wasInterrupted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if emulator.title == nil {
                StartScreen(error: emulator.errorMessage) { isImporting = true }
            } else {
                gameplay
            }
        }
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.romTypes,
            onCompletion: handleImport
        )
        // Dropping a ROM onto the window works on both platforms and is the
        // fastest way in on the Mac.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            emulator.load(url: url)
            return true
        }
        .task { emulator.restoreLastSession() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .up]) { press in
            handleKey(press)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Only resume what the system interrupted, so a game the
                // player deliberately paused stays paused.
                if wasInterrupted { emulator.start() }
                wasInterrupted = false

            case .background:
                // The last reliable moment to write the save file.
                wasInterrupted = emulator.isRunning
                emulator.pause()

            default:
                // `.inactive` means different things per platform. On iOS it's
                // the app switcher or a notification being pulled down, and
                // stopping is right. On the Mac it only means another window
                // took focus, and a game that halts every time you glance at
                // another app is unusable.
                #if os(iOS)
                wasInterrupted = emulator.isRunning
                emulator.pause()
                #endif
            }
        }
    }

    // MARK: - Gameplay

    private var gameplay: some View {
        VStack(spacing: 0) {
            // A view of its own so that the sixty-times-a-second frame update
            // invalidates only the screen. Read here, `emulator.frame` would
            // make the whole body — toolbar, menus and all — depend on it.
            GameScreen(emulator: emulator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if os(iOS)
            TouchControls(emulator: emulator)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            #endif
        }
        .overlay(alignment: .top) {
            if !emulator.isRunning {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Open ROM", systemImage: "folder") { isImporting = true }
        }

        if emulator.title != nil {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    emulator.isRunning ? "Pause" : "Resume",
                    systemImage: emulator.isRunning ? "pause.fill" : "play.fill"
                ) {
                    emulator.togglePause()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Speed", selection: $emulator.speed) {
                    ForEach(Emulator.Speed.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu("Save states", systemImage: "square.and.arrow.down") {
                    ForEach(1...3, id: \.self) { slot in
                        Button("Save to slot \(slot)") { emulator.saveState(slot: slot) }
                    }
                    Divider()
                    ForEach(1...3, id: \.self) { slot in
                        Button("Load slot \(slot)") { emulator.loadState(slot: slot) }
                            .disabled(!emulator.hasState(slot: slot))
                    }
                    Divider()
                    Button("Reset", systemImage: "arrow.counterclockwise") { emulator.reset() }
                }
            }
        }
    }

    // MARK: - Input

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        emulator.load(url: url)
    }

    /// Both platforms get the same keyboard layout — an iPad with a keyboard
    /// attached is as good a way to play as a Mac.
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

    private static let romTypes: [UTType] = {
        let types = ["gb", "gbc"].compactMap { UTType(filenameExtension: $0) }
        // If the system has no idea what a .gb file is — which it won't, since
        // nothing declares that type — fall back to accepting any file and let
        // the header check reject the wrong ones.
        return types.isEmpty ? [.data] : types + [.data]
    }()
}

// MARK: - Screen

private struct GameScreen: View {
    let emulator: Emulator

    var body: some View {
        ScreenView(frame: emulator.frame)
    }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformView = NSView
#else
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformView = UIView
#endif

/// The screen, drawn by handing each frame straight to Core Animation.
///
/// This started as `Image(decorative:)`, which was correct and far too
/// expensive: a new `CGImage` sixty times a second sent SwiftUI through its
/// image-preparation path on every frame, colour-converting the bitmap on three
/// worker threads. Profiling put the emulator itself at well under half the
/// process's CPU and that pipeline at the rest.
///
/// A layer's `contents` takes a `CGImage` with none of that. The layer also
/// handles the scaling and the letterboxing, which is why there's no
/// `aspectRatio` here.
private extension PlatformView {
    /// `NSView.layer` is optional and only exists once the view asks for one;
    /// `UIView.layer` is neither. One name papers over the difference.
    var screenLayer: CALayer? {
        #if os(macOS)
        wantsLayer = true
        #endif
        return layer
    }
}

struct ScreenView: PlatformViewRepresentable {
    let frame: CGImage?

    func makeNSView(context: Context) -> PlatformView { makeView() }
    func updateNSView(_ view: PlatformView, context: Context) { update(view) }
    func makeUIView(context: Context) -> PlatformView { makeView() }
    func updateUIView(_ view: PlatformView, context: Context) { update(view) }

    private func makeView() -> PlatformView {
        let view = PlatformView()
        guard let layer = view.screenLayer else { return view }
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.contentsGravity = .resizeAspect
        // Every pixel is drawn at ten times its size or more, so smoothing
        // would turn a deliberately chunky picture into a blurry one.
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        return view
    }

    private func update(_ view: PlatformView) {
        guard let layer = view.screenLayer else { return }
        // Without this, Core Animation cross-fades between frames — a quarter
        // second of implicit animation applied to something that changes every
        // sixteen milliseconds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frame
        CATransaction.commit()
    }
}

// MARK: - Start screen

private struct StartScreen: View {
    let error: String?
    let open: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)

            Text("Cartridge")
                .font(.largeTitle.weight(.semibold))

            Text("Open a Game Boy ROM, or drop one here.")
                .foregroundStyle(.secondary)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Open ROM…", action: open)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
}

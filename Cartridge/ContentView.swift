//
//  ContentView.swift
//  Cartridge
//

import SwiftUI

struct ContentView: View {
    @State private var library = GameLibrary()
    @State private var emulator: Emulator?
    @State private var playing: GameEntry?

    var body: some View {
        NavigationStack {
            LibraryView(library: library, play: start)
                .navigationDestination(item: $playing) { _ in
                    if let emulator {
                        PlayerView(emulator: emulator) { playing = nil }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { openLaunchArgumentROM() }
    }

    private func start(_ entry: GameEntry) {
        // One emulator for the life of the app rather than one per game: it
        // owns an audio engine, and building a new one per launch means a new
        // audio graph each time.
        let engine = emulator ?? Emulator(library: library)
        emulator = engine
        engine.play(entry, romURL: library.romURL(for: entry))
        playing = entry
    }

    /// `-rom <path>` imports and launches a game straight away, which is how
    /// this gets tested without driving the file picker.
    private func openLaunchArgumentROM() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-rom"), flag + 1 < arguments.count else {
            return
        }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        guard let entry = try? library.importGame(from: url) else { return }
        start(entry)
    }
}

// MARK: - Screen

struct GameScreen: View {
    let emulator: Emulator

    var body: some View {
        // A view of its own so the sixty-times-a-second frame update
        // invalidates only the screen — read higher up, `emulator.frame` would
        // make the toolbar and everything else depend on it too.
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

#Preview {
    ContentView()
}

//
//  ContentView.swift
//  Cartridge
//

import SwiftUI

struct ContentView: View {
    @State private var library: GameLibrary
    @State private var emulator: Emulator
    @State private var playing: GameEntry?

    /// The player replaces the library rather than being pushed onto it.
    ///
    /// As a navigation destination it inherited a navigation bar, and hiding
    /// that bar didn't reclaim the space it had already reserved — the whole
    /// screen sat centred in the leftover, with a band of dead black above and
    /// below. A game wants the window, not a page inside one.
    ///
    /// Both objects below are built here, once, and neither is optional.
    ///
    /// The emulator used to be an optional created on first play, which meant
    /// the navigation destination read `if let emulator` — and a destination
    /// closure captured before that value was set pushed an *empty* screen. The
    /// game ran, the audio played, and there was nothing to look at. An empty
    /// `if let` branch is a silent blank page, so there shouldn't be one on the
    /// path to the only screen that matters.
    @MainActor
    init() {
        let library = GameLibrary()
        _library = State(initialValue: library)
        _emulator = State(initialValue: Emulator(library: library))
    }

    var body: some View {
        ZStack {
            if playing != nil {
                PlayerView(emulator: emulator) { playing = nil }
            } else {
                NavigationStack {
                    LibraryView(library: library, emulator: emulator, play: start)
                }
            }
        }
        .task {
            openLaunchArgumentROM()
            // `-scanServer` opens the cheat-search port without going through
            // Settings, which is how the Python side gets tested against the
            // real server rather than a stand-in for it.
            if ProcessInfo.processInfo.arguments.contains("-scanServer") {
                emulator.setScanServerEnabled(true)
            }
        }
        .task {
            // Resolving the container can take a moment, so it happens after
            // first paint rather than on the way to it. Until it lands, the app
            // is running on local storage and working normally.
            guard let cloud = await CloudStorage.resolveRoot() else { return }
            library.adoptCloudRoot(cloud)
        }
    }

    private func start(_ entry: GameEntry) {
        emulator.play(entry, romURL: library.romURL(for: entry))
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
    let surround: Color

    var body: some View {
        // A view of its own so the sixty-times-a-second frame update
        // invalidates only the screen — read higher up, `emulator.frame` would
        // make the toolbar and everything else depend on it too.
        ScreenView(frame: emulator.frame, surround: surround)
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
    /// What the letterboxing either side of the picture is filled with.
    let surround: Color

    func makeNSView(context: Context) -> PlatformView { makeView() }
    func updateNSView(_ view: PlatformView, context: Context) { update(view) }
    func makeUIView(context: Context) -> PlatformView { makeView() }
    func updateUIView(_ view: PlatformView, context: Context) { update(view) }

    /// Takes whatever space it's offered.
    ///
    /// Without this a representable reports the wrapped view's own size, which
    /// for a plain `UIView`/`NSView` is nothing — so `maxHeight: .infinity` had
    /// no effect, the screen stayed small and the layout floated in the middle
    /// of a lot of black. The layer letterboxes inside whatever it's given, so
    /// accepting the full proposal is safe.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: PlatformView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: GameBoy.screenSize.width, height: GameBoy.screenSize.height)
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: PlatformView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: GameBoy.screenSize.width, height: GameBoy.screenSize.height)
        )
    }

    private func makeView() -> PlatformView {
        let view = PlatformView()
        guard let layer = view.screenLayer else { return view }
        layer.backgroundColor = surround.cgColour
        layer.contentsGravity = .resizeAspect
        // Every pixel is drawn at ten times its size or more, so smoothing
        // would turn a deliberately chunky picture into a blurry one.
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        return view
    }

    private func update(_ view: PlatformView) {
        guard let layer = view.screenLayer else { return }
        layer.backgroundColor = surround.cgColour
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

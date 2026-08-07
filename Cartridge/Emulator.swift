//
//  Emulator.swift
//  Cartridge
//

import Foundation
import CoreGraphics
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owns the running core and everything around it that isn't emulation: the
/// frame clock, save files, and turning a framebuffer into something SwiftUI
/// can draw.
///
/// The core runs on its own serial queue and the UI never touches it directly.
/// That isn't about performance — a Game Boy needs about 2% of a core — it's so
/// that a slow frame in SwiftUI can't stretch emulated time, which is what makes
/// audio and gameplay speed wobble in naïve ports.
@Observable
@MainActor
final class Emulator {

    enum Speed: Double, CaseIterable, Identifiable {
        case half = 0.5, normal = 1, double = 2, quadruple = 4
        var id: Self { self }
        var label: String {
            self == .normal ? "1×" : (rawValue == 0.5 ? "½×" : "\(Int(rawValue))×")
        }
    }

    private(set) var frame: CGImage?
    private(set) var title: String?
    private(set) var subtitle: String?
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    init(library: GameLibrary) {
        self.library = library
        palette = .named(UserDefaults.standard.string(forKey: "palette") ?? "dmg")
        ghosting = UserDefaults.standard.bool(forKey: "ghosting")
        prefersColor = UserDefaults.standard.object(forKey: "prefersColor") as? Bool ?? true
        observeTermination()
    }

    /// Quitting mid-game has to write the battery save.
    ///
    /// Backgrounding already does, but on the Mac quitting doesn't reliably go
    /// through a scene phase change first — and the thing at stake is somebody's
    /// save file, which is the one piece of state the app can't reconstruct.
    private func observeTermination() {
        #if os(macOS)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.pause() }
        }
    }

    var speed: Speed = .normal { didSet { restartClock() } }
    /// Held rather than toggled — the fast-forward button in the UI.
    var isBoosting = false { didSet { restartClock() } }
    var palette: ScreenPalette = .dmg {
        didSet {
            queue.async { self.core.palette = self.palette }
            UserDefaults.standard.set(palette.id, forKey: "palette")
        }
    }

    var ghosting = false {
        didSet {
            queue.async { self.core.ghosting = self.ghosting }
            UserDefaults.standard.set(ghosting, forKey: "ghosting")
        }
    }

    /// Whether a Color cartridge wakes the Color hardware.
    ///
    /// Dual-mode games run either way, so this is a real choice — Silver in
    /// green is how most people first played it. Changing it is a power cycle,
    /// which is why the game is reloaded rather than patched underneath.
    var prefersColor = true {
        didSet {
            UserDefaults.standard.set(prefersColor, forKey: "prefersColor")
            guard let entry else { return }
            play(entry, romURL: library.romURL(for: entry))
        }
    }

    /// True when the running game is actually using the Color hardware, which
    /// is what decides whether a monochrome palette means anything.
    private(set) var isColorRunning = false

    /// The last several seconds of picture, for saving a clip.
    nonisolated(unsafe) private let clipRecorder = ClipRecorder()

    /// True once there's enough buffered to be worth saving.
    var canSaveClip: Bool { queue.sync { clipRecorder.isReady } }

    func makeClip() -> Data? { queue.sync { clipRecorder.makeGIF() } }
    func makeScreenshot() -> CGImage? { queue.sync { clipRecorder.latestFrame() } }

    /// Isolated by `queue` rather than by the actor: every access happens
    /// inside a block dispatched there, including the ones that look
    /// synchronous. The compiler can't see a serial queue as an isolation
    /// domain, so the contract has to be stated rather than inferred.
    nonisolated(unsafe) private let core = GameBoy()
    nonisolated(unsafe) private let audio = AudioOutput()
    private let queue = DispatchQueue(label: "me.jacobsilva.Cartridge.emulation", qos: .userInteractive)
    private var clock: DispatchSourceTimer?
    private(set) var entry: GameEntry?
    private let library: GameLibrary
    /// When the current stretch of play began, for the library's time counter.
    private var sessionStart: Date?
    /// Cartridge RAM is written back when play stops rather than when it
    /// changes, because games write to it constantly and a flush per write
    /// would mean a disk write per frame.
    private var hasBattery = false

    // MARK: - Loading

    /// Starts a game from the library.
    func play(_ entry: GameEntry, romURL url: URL) {
        do {
            let data = try Data(contentsOf: url)
            stop()

            try queue.sync {
                // Set before insertion: which machine the cartridge boots on is
                // decided at power-on, not afterwards.
                core.prefersColor = prefersColor
                try core.insert(cartridge: data)
            }
            isColorRunning = queue.sync { core.colorMode }

            self.entry = entry
            title = entry.title
            subtitle = entry.subtitle
            errorMessage = nil

            clipRecorder.reset()
            queue.sync {
                core.palette = palette
                core.ghosting = ghosting
            }

            hasBattery = entry.hasBattery
            if hasBattery, let saved = SaveStore.batteryRAM(for: entry.id) {
                queue.sync { core.batteryRAM = saved }
            }

            // Picking the game back up exactly where it was left. A state from
            // a different build of the emulator may not decode; failing to
            // restore just means starting at the title screen, which is what
            // would have happened anyway.
            if Self.autoResumeEnabled, let resume = SaveStore.autoState(for: entry.id) {
                queue.sync { try? core.loadState(resume) }
            }

            start()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That game couldn't be opened."
            self.entry = nil
            title = nil
            subtitle = nil
        }
    }

    // MARK: - Running

    func start() {
        guard entry != nil, !isRunning else { return }
        isRunning = true
        sessionStart = .now
        audio.start()
        restartClock()
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        clock?.cancel()
        clock = nil
        audio.stop()
        flushBatteryRAM()
        recordSession()
    }

    /// Whether leaving a game keeps your place.
    ///
    /// Read fresh each time rather than cached: it's a switch someone can flip
    /// between one session and the next, and a stale copy would mean the
    /// setting appearing not to take until the app restarted.
    static var autoResumeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoResume")
    }

    /// Where the machine was, written whenever play stops.
    ///
    /// Backing out of a game used to restart it from the title screen, which
    /// for an hour of unsaved progress is a misclick that costs an evening.
    /// This is the same thing a save state is, taken without being asked.
    private func writeAutoState() {
        guard let entry, Self.autoResumeEnabled else { return }
        queue.sync {
            guard let data = try? core.saveState() else { return }
            SaveStore.write(autoState: data, for: entry.id)
        }
    }

    /// Play time and the tile image, written whenever play stops — which is
    /// also every time the app is backgrounded, so a session that ends by the
    /// phone being locked still counts.
    private func recordSession() {
        guard let entry else { return }
        writeAutoState()
        if let start = sessionStart {
            library.recordPlay(entry, seconds: Date.now.timeIntervalSince(start))
            sessionStart = nil
        }
        if let frame { library.recordCover(frame, for: entry) }
    }

    func stop() {
        pause()
        frame = nil
        title = nil
        subtitle = nil
        entry = nil
    }

    func togglePause() { isRunning ? pause() : start() }

    private func restartClock() {
        guard isRunning else { return }
        clock?.cancel()

        let multiplier = isBoosting ? max(speed.rawValue, 4) : speed.rawValue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The interval stays at the hardware's frame rate and the *number of
        // frames per tick* changes with speed. Shortening the interval instead
        // would work until it went below what the timer can schedule.
        let framesPerTick = max(Int(multiplier.rounded()), 1)
        let interval = Double(framesPerTick) / (GameBoy.frameRate * multiplier)

        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            for _ in 0..<framesPerTick {
                self.core.runFrame()
                self.audio.enqueue(self.core.drainAudio())
            }

            // Only the finished frame crosses back to the main actor; the core
            // itself never leaves this queue.
            let pixels = self.core.framebuffer
            self.clipRecorder.record(pixels, palette: self.core.palette)
            Task { @MainActor in self.frame = Self.image(from: pixels) }
        }
        timer.resume()
        clock = timer
    }

    // MARK: - Input

    /// How long a button is guaranteed to stay down.
    ///
    /// A game reads the joypad port once or twice a frame. A quick tap can be
    /// pressed and released inside a single frame, and then it never happened —
    /// which is why tapping did nothing and only holding worked. Four frames is
    /// far below what anyone can perceive as lag and far above what any game
    /// can miss.
    private static let minimumHold: Duration = .milliseconds(70)

    /// Bumped on every press so a delayed release can tell whether the button
    /// has been pressed again since — otherwise a fast double tap releases the
    /// second press.
    private var pressGeneration: [ConsoleButton: Int] = [:]
    private var pressStarted: [ConsoleButton: ContinuousClock.Instant] = [:]

    func set(_ button: ConsoleButton, pressed: Bool) {
        if pressed {
            pressGeneration[button, default: 0] += 1
            pressStarted[button] = .now
            queue.async { self.core.set(button, pressed: true) }
            return
        }

        let held = pressStarted[button].map { ContinuousClock.now - $0 } ?? Self.minimumHold
        pressStarted[button] = nil

        // Anything held long enough to have been seen is released immediately.
        // Padding every release would add lag to the ones that don't need it —
        // a direction would keep walking after the thumb came off.
        guard held < Self.minimumHold else {
            queue.async { self.core.set(button, pressed: false) }
            return
        }

        let generation = pressGeneration[button] ?? 0
        Task { @MainActor in
            try? await Task.sleep(for: Self.minimumHold - held)
            guard pressGeneration[button] == generation else { return }
            queue.async { self.core.set(button, pressed: false) }
        }
    }

    func reset() {
        queue.async { self.core.reset() }
    }

    // MARK: - Saving

    func saveState(slot: Int) {
        guard let saveKey = entry?.id else { return }
        queue.async {
            guard let data = try? self.core.saveState() else { return }
            SaveStore.write(state: data, for: saveKey, slot: slot)
        }
    }

    func loadState(slot: Int) {
        guard let saveKey = entry?.id,
              let data = SaveStore.state(for: saveKey, slot: slot) else { return }
        queue.async { try? self.core.loadState(data) }
    }

    func hasState(slot: Int) -> Bool {
        guard let saveKey = entry?.id else { return false }
        return SaveStore.hasState(for: saveKey, slot: slot)
    }

    /// Called when the app goes to the background, and on pause. Losing
    /// cartridge RAM is losing someone's save file, so it's worth being eager.
    func flushBatteryRAM() {
        guard let saveKey = entry?.id, hasBattery else { return }
        // Synchronous deliberately. This runs when play stops, not per frame,
        // and one of the callers is the app on its way out — an async write
        // there would be a save file that never lands.
        queue.sync {
            guard let ram = core.batteryRAM else { return }
            SaveStore.write(batteryRAM: ram, for: saveKey)
        }
    }

    // MARK: - Presentation

    /// Packed pixels straight into a `CGImage`, without interpolation.
    ///
    /// The screen is 160×144 being drawn at up to twenty times that, so any
    /// smoothing turns a deliberately chunky image into a blurry one.
    nonisolated private static func image(from pixels: [UInt32]) -> CGImage? {
        FrameImage.make(from: pixels)
    }
}

/// Where saves live on disk.
///
/// Cartridge RAM uses the `.sav` name and layout every other emulator uses, so
/// a save can be carried in or out without conversion.
enum SaveStore {
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cartridge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func url(_ name: String) -> URL {
        // Titles come from filenames, which can contain anything.
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return root.appending(path: safe)
    }

    static func batteryRAM(for key: String) -> Data? {
        try? Data(contentsOf: url("\(key).sav"))
    }

    static func write(batteryRAM: Data, for key: String) {
        try? batteryRAM.write(to: url("\(key).sav"), options: .atomic)
    }

    /// The state written automatically when play stops, kept apart from the
    /// three the player controls so it can never overwrite one of theirs.
    static func autoState(for key: String) -> Data? {
        try? Data(contentsOf: url("\(key).resume"))
    }

    static func write(autoState: Data, for key: String) {
        try? autoState.write(to: url("\(key).resume"), options: .atomic)
    }

    static func state(for key: String, slot: Int) -> Data? {
        try? Data(contentsOf: url("\(key).state\(slot)"))
    }

    /// Deliberately not `state(for:slot:) != nil`. That version read every byte
    /// of the file to answer a question about its existence, from a menu that
    /// SwiftUI re-evaluated on every frame.
    static func hasState(for key: String, slot: Int) -> Bool {
        FileManager.default.fileExists(atPath: url("\(key).state\(slot)").path)
    }

    static func write(state: Data, for key: String, slot: Int) {
        try? state.write(to: url("\(key).state\(slot)"), options: .atomic)
    }
}

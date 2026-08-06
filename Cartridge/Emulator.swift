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

            try queue.sync { try core.insert(cartridge: data) }

            self.entry = entry
            title = entry.title
            subtitle = entry.subtitle
            errorMessage = nil

            hasBattery = entry.hasBattery
            if hasBattery, let saved = SaveStore.batteryRAM(for: entry.id) {
                queue.sync { core.batteryRAM = saved }
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

    /// Play time and the tile image, written whenever play stops — which is
    /// also every time the app is backgrounded, so a session that ends by the
    /// phone being locked still counts.
    private func recordSession() {
        guard let entry else { return }
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
            Task { @MainActor in self.frame = Self.image(from: pixels) }
        }
        timer.resume()
        clock = timer
    }

    // MARK: - Input

    func set(_ button: ConsoleButton, pressed: Bool) {
        queue.async { self.core.set(button, pressed: pressed) }
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
    nonisolated private static let colorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    nonisolated private static func image(from pixels: [UInt32]) -> CGImage? {
        let width = GameBoy.screenSize.width
        let height = GameBoy.screenSize.height

        return pixels.withUnsafeBufferPointer { buffer -> CGImage? in
            guard let provider = CGDataProvider(data: Data(buffer: buffer) as CFData) else {
                return nil
            }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                // sRGB rather than DeviceRGB: the compositor converts anything
                // whose colour space it can't match, and that conversion is a
                // full re-render of the bitmap on every frame.
                space: Self.colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
            )
        }
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

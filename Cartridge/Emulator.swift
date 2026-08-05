//
//  Emulator.swift
//  Cartridge
//

import Foundation
import CoreGraphics
import Observation

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

    var speed: Speed = .normal { didSet { restartClock() } }
    /// Held rather than toggled — the fast-forward button in the UI.
    var isBoosting = false { didSet { restartClock() } }

    /// Isolated by `queue` rather than by the actor: every access happens
    /// inside a block dispatched there, including the ones that look
    /// synchronous. The compiler can't see a serial queue as an isolation
    /// domain, so the contract has to be stated rather than inferred.
    nonisolated(unsafe) private let core = GameBoy()
    private let queue = DispatchQueue(label: "me.jacobsilva.Cartridge.emulation", qos: .userInteractive)
    private var clock: DispatchSourceTimer?
    private var saveKey: String?
    /// Cartridge RAM is written back when play stops rather than when it
    /// changes, because games write to it constantly and a flush per write
    /// would mean a disk write per frame.
    private var hasBattery = false

    // MARK: - Loading

    func load(url: URL) {
        // Files handed over by the document picker live outside the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            stop()

            try queue.sync {
                try core.insert(cartridge: data)
            }

            let key = url.deletingPathExtension().lastPathComponent
            saveKey = key
            title = url.deletingPathExtension().lastPathComponent
            subtitle = queue.sync { core.header?.description }
            errorMessage = nil

            hasBattery = queue.sync { core.header?.hasBattery ?? false }
            if hasBattery, let saved = SaveStore.batteryRAM(for: key) {
                queue.sync { core.batteryRAM = saved }
            }
            start()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That file couldn't be opened."
            title = nil
            subtitle = nil
        }
    }

    // MARK: - Running

    func start() {
        guard title != nil, !isRunning else { return }
        isRunning = true
        restartClock()
    }

    func pause() {
        isRunning = false
        clock?.cancel()
        clock = nil
        flushBatteryRAM()
    }

    func stop() {
        pause()
        frame = nil
        title = nil
        subtitle = nil
        saveKey = nil
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
            for _ in 0..<framesPerTick { self.core.runFrame() }
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
        guard let saveKey else { return }
        queue.async {
            guard let data = try? self.core.saveState() else { return }
            SaveStore.write(state: data, for: saveKey, slot: slot)
        }
    }

    func loadState(slot: Int) {
        guard let saveKey, let data = SaveStore.state(for: saveKey, slot: slot) else { return }
        queue.async { try? self.core.loadState(data) }
    }

    func hasState(slot: Int) -> Bool {
        guard let saveKey else { return false }
        return SaveStore.state(for: saveKey, slot: slot) != nil
    }

    /// Called when the app goes to the background, and on pause. Losing
    /// cartridge RAM is losing someone's save file, so it's worth being eager.
    func flushBatteryRAM() {
        guard let saveKey, hasBattery else { return }
        queue.async {
            guard let ram = self.core.batteryRAM else { return }
            SaveStore.write(batteryRAM: ram, for: saveKey)
        }
    }

    // MARK: - Presentation

    /// Packed pixels straight into a `CGImage`, without interpolation.
    ///
    /// The screen is 160×144 being drawn at up to twenty times that, so any
    /// smoothing turns a deliberately chunky image into a blurry one.
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
                space: CGColorSpaceCreateDeviceRGB(),
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

    static func write(state: Data, for key: String, slot: Int) {
        try? state.write(to: url("\(key).state\(slot)"), options: .atomic)
    }
}

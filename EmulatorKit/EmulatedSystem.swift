//
//  EmulatedSystem.swift
//  EmulatorKit
//

import Foundation

/// The screen a system draws to.
public struct ScreenSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var aspectRatio: Double { Double(width) / Double(height) }
}

/// Every button any supported handheld has.
///
/// A superset rather than one enum per system: the shell binds keys and draws
/// on-screen controls once, and a core simply ignores buttons its hardware
/// never had. The Game Boy has no shoulder buttons; it doesn't need to know
/// they exist elsewhere.
public enum Button: String, CaseIterable, Sendable {
    case up, down, left, right
    case a, b, select, start
    /// Game Boy Advance only.
    case l, r

    public var label: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .l: "L"
        case .r: "R"
        case .select: "SELECT"
        case .start: "START"
        default: rawValue.capitalized
        }
    }
}

public enum SystemError: Error, LocalizedError {
    case unsupportedCartridge(String)
    case corruptSaveState
    case romTooSmall

    public var errorDescription: String? {
        switch self {
        case .unsupportedCartridge(let detail): "Unsupported cartridge: \(detail)"
        case .corruptSaveState: "That save state couldn't be read."
        case .romTooSmall: "That file is too small to be a ROM."
        }
    }
}

/// A console the shell can run.
///
/// This exists so the parts that aren't the emulator — rendering, input, audio,
/// save states, fast-forward, file handling — get written once. A Game Boy
/// Advance core is a second conformance rather than a second application, and
/// notably *not* a replacement: real GBA hardware runs Game Boy games on a
/// separate CPU, so supporting both libraries genuinely means two cores.
public protocol EmulatedSystem: AnyObject {
    /// Shown in the UI.
    static var name: String { get }
    /// File extensions this core claims, lowercased and without the dot.
    static var fileExtensions: [String] { get }
    static var screenSize: ScreenSize { get }
    /// Frames per second the hardware runs at. The Game Boy's is famously not
    /// 60 — it's 59.7275, and audio drifts audibly if you pretend otherwise.
    static var frameRate: Double { get }
    /// Audio sample rate this core produces.
    static var sampleRate: Double { get }

    init()

    /// Loads a ROM and resets. Throws rather than trapping: opening the wrong
    /// file is a normal thing for a person to do.
    func insert(cartridge: Data) throws

    /// Advances emulation by exactly one video frame.
    func runFrame()

    func set(_ button: Button, pressed: Bool)

    /// The completed frame, one packed 0xAARRGGBB pixel per element, row-major.
    var framebuffer: [UInt32] { get }

    /// Interleaved stereo samples produced since the last call, and cleared.
    func drainAudio() -> [Float]

    /// Cartridge RAM to persist between launches, when the cartridge has a
    /// battery. Nil when there's nothing worth saving.
    var batteryRAM: Data? { get set }

    func saveState() throws -> Data
    func loadState(_ data: Data) throws
}

public extension EmulatedSystem {
    static func claims(fileExtension: String) -> Bool {
        fileExtensions.contains(fileExtension.lowercased())
    }
}

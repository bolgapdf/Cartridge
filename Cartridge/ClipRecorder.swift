//
//  ClipRecorder.swift
//  Cartridge
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a packed framebuffer into an image.
///
/// Shared by the live screen, the library tiles and the clip encoder, all of
/// which want the same thing from the same bytes.
enum FrameImage {
    /// sRGB rather than DeviceRGB: the compositor converts anything whose
    /// colour space it can't match, and that conversion is a full re-render of
    /// the bitmap on every frame.
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func make(from pixels: [UInt32]) -> CGImage? {
        let width = GameBoy.screenSize.width
        let height = GameBoy.screenSize.height

        return pixels.withUnsafeBufferPointer { buffer -> CGImage? in
            guard let provider = CGDataProvider(data: Data(buffer: buffer) as CFData) else {
                return nil
            }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
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

/// Keeps the last few seconds of picture so a clip can be saved after the fact.
///
/// Recording *after* something happens is the wrong way round — by the time you
/// know a moment was worth keeping, it's gone. So the buffer always runs, and
/// the button reaches backwards.
///
/// Only ever touched on the emulation queue; the shell reaches it through
/// `Emulator`, which hops there first.
final class ClipRecorder: @unchecked Sendable {

    /// Every fourth frame, which is about 15 per second — a normal rate for a
    /// GIF, and a quarter of the memory of keeping every one.
    private static let frameInterval = 4
    private static let seconds = 6.0

    private var frames: [[UInt32]] = []
    private var counter = 0

    private var capacity: Int {
        Int(GameBoy.frameRate * Self.seconds) / Self.frameInterval
    }

    var isReady: Bool { frames.count > 4 }

    func record(_ pixels: [UInt32], palette: ScreenPalette) {
        counter += 1
        guard counter >= Self.frameInterval else { return }
        counter = 0

        frames.append(pixels)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func reset() {
        frames.removeAll(keepingCapacity: true)
        counter = 0
    }

    /// The most recent still, for a plain screenshot.
    func latestFrame() -> CGImage? {
        frames.last.flatMap(FrameImage.make)
    }

    /// Encodes what's buffered as an animated GIF.
    ///
    /// GIF because it plays everywhere with no player and no codec argument,
    /// and because a 160×144 four-colour image is the one case where GIF's
    /// palette limit costs nothing at all.
    func makeGIF() -> Data? {
        guard !frames.isEmpty else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frames.count, nil
        ) else { return nil }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let delay = Double(Self.frameInterval) / GameBoy.frameRate
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
        ] as CFDictionary

        for pixels in frames {
            guard let image = FrameImage.make(from: pixels) else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

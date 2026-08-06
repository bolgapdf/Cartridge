//
//  ClipExport.swift
//  Cartridge
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// A file on its way out of the app.
struct ClipExport: Identifiable {
    let url: URL
    var id: URL { url }
}

extension FrameImage {
    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

#if os(iOS)
/// The system share sheet, which SwiftUI still has no native equivalent of for
/// arbitrary file URLs.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

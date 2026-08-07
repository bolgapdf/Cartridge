//
//  CoverPicker.swift
//  Cartridge
//

import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Lets a game's artwork be chosen from the photo library or from a file.
///
/// Box art can't be shipped with the app and can't be derived from a ROM, so
/// the honest way to get a shelf that looks like a shelf is to let people
/// supply the pictures. A screenshot of where you stopped remains the default,
/// and is often the better one.
struct CoverPicker: ViewModifier {
    let library: GameLibrary
    @Binding var target: GameEntry?

    #if os(iOS)
    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                selection: $selection,
                matching: .images
            )
            .onChange(of: selection) { _, item in
                guard let item, let entry = target else { return }
                Task { await load(item, for: entry) }
            }
    }

    private func load(_ item: PhotosPickerItem, for entry: GameEntry) async {
        defer {
            selection = nil
            target = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = CoverImage.prepare(data)
        else { return }
        library.setCustomCover(image, for: entry)
    }
    #else
    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            allowedContentTypes: [.image]
        ) { result in
            defer { target = nil }
            guard case .success(let url) = result, let entry = target else { return }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url),
                  let image = CoverImage.prepare(data)
            else { return }
            library.setCustomCover(image, for: entry)
        }
    }
    #endif
}

enum CoverImage {
    /// The longest edge a stored cover is allowed.
    ///
    /// A tile is around 200 points wide. Keeping a 12-megapixel photo for it
    /// would cost more disk than every ROM in the library put together, and
    /// decoding one per tile is what turns a grid into a slideshow.
    private static let maximumEdge = 640

    static func prepare(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // Thumbnail creation rather than decode-then-resize: this way the full
        // image is never materialised, and the orientation tag is honoured
        // rather than leaving a photo shot in portrait lying on its side.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

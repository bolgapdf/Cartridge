//
//  CloudStorage.swift
//  Cartridge
//

import Foundation

/// Where the games and saves live, and how they get between devices.
///
/// iCloud Documents rather than CloudKit: everything here is already a file,
/// and the system will sync a directory for free. CloudKit would mean modelling
/// a ROM as a record to get the same result with more moving parts.
///
/// The app never *depends* on iCloud. It starts on local storage and adopts the
/// container once it resolves, because resolving it can take a moment and doing
/// that on the way to first paint would be a hang at launch.
enum CloudStorage {

    static let localRoot: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cartridge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// True when the user is signed into iCloud at all. This one is cheap;
    /// resolving the container is not.
    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// The container's Documents folder, or nil if iCloud isn't available.
    ///
    /// Documents rather than the container root so the files show up in the
    /// Files app — which is also how a ROM gets onto a device that has no way
    /// to receive one otherwise.
    static func resolveRoot() async -> URL? {
        await Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            else { return nil }

            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            for folder in ["Games", "Covers"] {
                try? FileManager.default.createDirectory(
                    at: documents.appending(path: folder, directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
            return documents
        }.value
    }

    // MARK: - Reading

    /// Reads a file, waiting for iCloud to fetch it if it hasn't yet.
    ///
    /// A file made on another device arrives as a placeholder — the name is
    /// there and the bytes are not. Reading one without asking for it first
    /// returns nothing, which would look exactly like a save that had gone
    /// missing.
    static func read(_ url: URL, waitingUpTo timeout: TimeInterval = 8) -> Data? {
        if let data = try? Data(contentsOf: url) { return data }

        guard isPlaceholder(url) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) { return data }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    private static func isPlaceholder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// Starts fetching everything in the container, so that opening the app on
    /// a new device doesn't mean waiting at the moment you tap a game.
    static func prefetch(_ root: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in walker where isPlaceholder(url) {
            try? manager.startDownloadingUbiquitousItem(at: url)
        }
    }

    // MARK: - Writing

    /// Writes through a file coordinator, which is what stops a half-written
    /// file being uploaded while it's still being written.
    static func write(_ data: Data, to url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { destination in
            try? data.write(to: destination, options: .atomic)
        }
    }

    // MARK: - Conflicts

    /// Settles a conflicting file by keeping the newest and preserving the rest.
    ///
    /// Two devices playing the same cartridge will eventually both write its
    /// battery save. iCloud can't merge them and neither can anything else — a
    /// save file is an opaque blob. So the newest becomes the live one and the
    /// losers are kept alongside under their own names.
    ///
    /// Deleting the loser is the obvious implementation and the one that
    /// silently destroys somebody's afternoon.
    @discardableResult
    static func resolveConflicts(at url: URL) -> [URL] {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty
        else { return [] }

        var preserved: [URL] = []
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]

        for version in conflicts {
            let name = url.deletingPathExtension().lastPathComponent
            let date = version.modificationDate ?? .now
            let copy = url.deletingLastPathComponent()
                .appending(path: "\(name) (conflict \(stamp.string(from: date))).\(url.pathExtension)")

            if (try? version.replaceItem(at: copy)) != nil {
                preserved.append(copy)
            }
            version.isResolved = true
        }

        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return preserved
    }
}

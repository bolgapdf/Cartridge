//
//  GameLibrary.swift
//  Cartridge
//

import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One game the app has been given.
///
/// Identified by a hash of the ROM itself rather than by its filename, so the
/// same game imported twice is the same entry, and renaming the file it came
/// from doesn't orphan a year of saves.
struct GameEntry: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var mapper: String
    var romBytes: Int
    var hasBattery: Bool
    var supportsColor: Bool
    var addedAt: Date
    var lastPlayedAt: Date?
    /// Bumped whenever the artwork changes, so the grid knows to reload it —
    /// a file being overwritten on disk isn't something a view can observe.
    var coverVersion = 0
    /// Set when the artwork was chosen rather than captured. A chosen cover is
    /// never replaced by a screenshot; the whole point of picking one is that
    /// it stops changing.
    var hasCustomCover = false
    /// Total time spent in this game, for the library's second line.
    var secondsPlayed: Double = 0

    var subtitle: String {
        var parts = [mapper, "\(romBytes / 1024) KB"]
        if supportsColor { parts.append("Color") }
        if hasBattery { parts.append("Battery") }
        return parts.joined(separator: " · ")
    }

    var playedDescription: String? {
        guard secondsPlayed >= 60 else { return lastPlayedAt == nil ? nil : "Played briefly" }
        let hours = Int(secondsPlayed) / 3600
        let minutes = (Int(secondsPlayed) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m played" : "\(minutes)m played"
    }
}

/// The games on this device, and the files belonging to them.
///
/// Importing copies the ROM into the app's own storage rather than keeping a
/// reference to wherever it came from. That's what makes the library a library:
/// the file can be deleted, the folder renamed, the device restored, and the
/// game is still here. It's also the only arrangement that can work on a device
/// with no file picker at all, which is where this is heading.
@Observable
@MainActor
final class GameLibrary {

    private(set) var games: [GameEntry] = []

    /// Mutable because the app starts on local storage and moves to iCloud
    /// once the container resolves, which can take longer than first paint.
    private var root: URL
    private var romsDirectory: URL
    private var coversDirectory: URL
    /// Shown in Settings, so the answer to "is this syncing" isn't a guess.
    private(set) var isUsingCloud = false
    /// Decoding a PNG per tile per frame is enough to make scrolling stutter,
    /// and the grid re-evaluates constantly.
    private var coverCache: [String: CGImage] = [:]

    init() {
        let base = CloudStorage.localRoot
        root = base
        romsDirectory = base.appending(path: "Games", directoryHint: .isDirectory)
        coversDirectory = base.appending(path: "Covers", directoryHint: .isDirectory)

        for directory in [root, romsDirectory, coversDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - iCloud

    /// Moves onto the iCloud container, bringing anything local along.
    ///
    /// One direction only, and only for files the container doesn't already
    /// have. This isn't a sync engine — iCloud is the sync engine. All this
    /// does is decide which folder is the one being synced, once.
    func adoptCloudRoot(_ cloud: URL) {
        guard !isUsingCloud, cloud != root else { return }

        let localGames = games
        let manager = FileManager.default

        for directory in ["", "Games", "Covers"] {
            let source = directory.isEmpty ? root : root.appending(path: directory)
            let destination = directory.isEmpty ? cloud : cloud.appending(path: directory)
            guard let names = try? manager.contentsOfDirectory(atPath: source.path) else { continue }

            for name in names where !name.hasPrefix(".") {
                let from = source.appending(path: name)
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: from.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { continue }

                let to = destination.appending(path: name)
                guard !manager.fileExists(atPath: to.path) else { continue }
                try? manager.moveItem(at: from, to: to)
            }
        }

        root = cloud
        romsDirectory = cloud.appending(path: "Games", directoryHint: .isDirectory)
        coversDirectory = cloud.appending(path: "Covers", directoryHint: .isDirectory)
        isUsingCloud = true

        load()
        merge(localGames)
        CloudStorage.prefetch(cloud)
    }

    /// Folds entries that only existed locally into whatever the container
    /// already knew about, keeping whichever record was played more recently.
    private func merge(_ incoming: [GameEntry]) {
        var changed = false
        for entry in incoming {
            guard FileManager.default.fileExists(atPath: romURL(for: entry.id).path) else { continue }

            if let index = games.firstIndex(where: { $0.id == entry.id }) {
                let mine = games[index]
                let newer = (entry.lastPlayedAt ?? .distantPast) > (mine.lastPlayedAt ?? .distantPast)
                if newer {
                    // Play time is the sum of two devices' sessions rather than
                    // whichever number happens to be larger.
                    var merged = entry
                    merged.secondsPlayed = max(entry.secondsPlayed, mine.secondsPlayed)
                    games[index] = merged
                    changed = true
                }
            } else {
                games.append(entry)
                changed = true
            }
        }
        if changed {
            sortGames()
            save()
        }
    }

    // MARK: - Save files

    private func saveURL(_ key: String, _ suffix: String) -> URL {
        root.appending(path: "\(key).\(suffix)")
    }

    func batteryRAM(for key: String) -> Data? {
        let url = saveURL(key, "sav")
        CloudStorage.resolveConflicts(at: url)
        return CloudStorage.read(url)
    }

    func write(batteryRAM: Data, for key: String) {
        CloudStorage.write(batteryRAM, to: saveURL(key, "sav"))
    }

    func state(for key: String, slot: Int) -> Data? {
        CloudStorage.read(saveURL(key, "state\(slot)"))
    }

    func write(state: Data, for key: String, slot: Int) {
        CloudStorage.write(state, to: saveURL(key, "state\(slot)"))
    }

    /// Deliberately not `state(for:slot:) != nil`. That version read every byte
    /// of the file to answer a question about its existence, from a menu
    /// SwiftUI re-evaluated on every frame — and over iCloud it would also
    /// trigger a download to do it.
    func hasState(for key: String, slot: Int) -> Bool {
        FileManager.default.fileExists(atPath: saveURL(key, "state\(slot)").path)
    }

    func autoState(for key: String) -> Data? {
        CloudStorage.read(saveURL(key, "resume"))
    }

    func write(autoState: Data, for key: String) {
        CloudStorage.write(autoState, to: saveURL(key, "resume"))
    }

    // MARK: - Importing

    @discardableResult
    func importGame(from url: URL) throws -> GameEntry {
        // A file handed over by the document picker lives outside the sandbox
        // and is only reachable for as long as the scope is held.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        // Parsed before anything is written, so an unsupported cartridge fails
        // without leaving a half-imported game behind.
        let cartridge = try GameCartridge(rom: [UInt8](data))
        let identifier = Self.identifier(for: data)

        if let existing = games.first(where: { $0.id == identifier }) {
            return existing
        }

        try data.write(to: romURL(for: identifier), options: .atomic)

        let header = cartridge.header
        let entry = GameEntry(
            id: identifier,
            // Header titles are terse and often truncated. The filename is
            // usually what a person actually calls the game.
            title: Self.displayTitle(fileName: url.deletingPathExtension().lastPathComponent,
                                     headerTitle: header.title),
            mapper: header.mapperName,
            romBytes: data.count,
            hasBattery: header.hasBattery,
            supportsColor: header.supportsColor,
            addedAt: .now
        )

        adoptLegacySaves(named: url.deletingPathExtension().lastPathComponent, for: entry)

        games.append(entry)
        sortGames()
        save()
        return entry
    }

    /// Saves made before the library existed were keyed by filename. Moving
    /// them across is a few lines and the alternative is losing someone's game.
    private func adoptLegacySaves(named name: String, for entry: GameEntry) {
        let manager = FileManager.default
        let candidates = ["sav", "state1", "state2", "state3"]
        for suffix in candidates {
            let old = root.appending(path: "\(name).\(suffix)")
            let new = root.appending(path: "\(entry.id).\(suffix)")
            guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else {
                continue
            }
            try? manager.moveItem(at: old, to: new)
        }
    }

    private static func displayTitle(fileName: String, headerTitle: String) -> String {
        // Dumped ROMs carry a tail of bracketed region and revision tags that
        // nobody wants to read in a grid.
        var cleaned = fileName
        while let open = cleaned.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            cleaned = String(cleaned[cleaned.startIndex..<open])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("-") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        if !cleaned.isEmpty { return cleaned }
        return headerTitle.isEmpty ? "Untitled" : headerTitle.capitalized
    }

    /// A content hash, so the identity of a game is the game.
    private static func identifier(for data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Files

    func romURL(for entry: GameEntry) -> URL { romURL(for: entry.id) }
    private func romURL(for id: String) -> URL { romsDirectory.appending(path: "\(id).gb") }
    func coverURL(for entry: GameEntry) -> URL {
        coversDirectory.appending(path: "\(entry.id).png")
    }

    func delete(_ entry: GameEntry) {
        let manager = FileManager.default
        try? manager.removeItem(at: romURL(for: entry))
        try? manager.removeItem(at: coverURL(for: entry))
        for suffix in ["sav", "state1", "state2", "state3"] {
            try? manager.removeItem(at: root.appending(path: "\(entry.id).\(suffix)"))
        }
        games.removeAll { $0.id == entry.id }
        save()
    }

    /// Throws away every "where you were" state.
    ///
    /// Called when resuming is switched off, so that off means off. Without it,
    /// switching the setting back on later would drop you into a state from
    /// whenever you last switched it off — which could be weeks ago and would
    /// look like the app losing your progress rather than restoring it.
    func clearAutoStates() {
        for entry in games {
            try? FileManager.default.removeItem(at: root.appending(path: "\(entry.id).resume"))
        }
    }

    // MARK: - Play records

    func recordPlay(_ entry: GameEntry, seconds: Double) {
        guard let index = games.firstIndex(where: { $0.id == entry.id }) else { return }
        games[index].lastPlayedAt = .now
        games[index].secondsPlayed += seconds
        sortGames()
        save()
    }

    /// The last frame of the last session, used as the tile when nothing has
    /// been chosen.
    ///
    /// It stands in for box art, which can't be shipped and can't be derived
    /// from a ROM — and it's arguably better: a shot of where you actually
    /// stopped tells you more than a cover does.
    func recordCover(_ image: CGImage, for entry: GameEntry) {
        guard !entry.hasCustomCover else { return }
        write(image, to: coverURL(for: entry))
        bumpCover(entry)
    }

    /// Artwork the player chose, which outranks the screenshot from then on.
    func setCustomCover(_ image: CGImage, for entry: GameEntry) {
        write(image, to: coverURL(for: entry))
        guard let index = games.firstIndex(where: { $0.id == entry.id }) else { return }
        games[index].hasCustomCover = true
        bumpCover(entry)
        save()
    }

    func clearCustomCover(for entry: GameEntry) {
        try? FileManager.default.removeItem(at: coverURL(for: entry))
        guard let index = games.firstIndex(where: { $0.id == entry.id }) else { return }
        games[index].hasCustomCover = false
        bumpCover(entry)
        save()
    }

    func cover(for entry: GameEntry) -> CGImage? {
        let key = "\(entry.id)-\(entry.coverVersion)"
        if let cached = coverCache[key] { return cached }

        let url = coverURL(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        coverCache[key] = image
        return image
    }

    private func bumpCover(_ entry: GameEntry) {
        guard let index = games.firstIndex(where: { $0.id == entry.id }) else { return }
        coverCache.removeValue(forKey: "\(entry.id)-\(games[index].coverVersion)")
        games[index].coverVersion += 1
        save()
    }

    private func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Persistence

    private var catalogueURL: URL { root.appending(path: "Library.json") }

    private func load() {
        CloudStorage.resolveConflicts(at: catalogueURL)
        guard let data = CloudStorage.read(catalogueURL),
              let stored = try? JSONDecoder().decode([GameEntry].self, from: data)
        else { return }

        // A catalogue entry whose ROM has gone is a broken tile that opens to
        // an error, so it's dropped instead.
        games = stored.filter { FileManager.default.fileExists(atPath: romURL(for: $0).path) }
        sortGames()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(games) else { return }
        CloudStorage.write(data, to: catalogueURL)
    }

    private func sortGames() {
        // Most recently played first, then most recently added — so the game
        // you're in the middle of is always the first tile.
        games.sort {
            switch ($0.lastPlayedAt, $1.lastPlayedAt) {
            case let (left?, right?): return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.addedAt > $1.addedAt
            }
        }
    }
}

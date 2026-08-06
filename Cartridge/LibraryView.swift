//
//  LibraryView.swift
//  Cartridge
//

import SwiftUI
import UniformTypeIdentifiers

/// The shelf. Every game the app has been given, most recently played first.
struct LibraryView: View {
    let library: GameLibrary
    let play: (GameEntry) -> Void

    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingDeletion: GameEntry?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    var body: some View {
        Group {
            if library.games.isEmpty {
                EmptyShelf { isImporting = true }
            } else {
                shelf
            }
        }
        .navigationTitle("Cartridge")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Game", systemImage: "plus") { isImporting = true }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: romTypes,
            allowsMultipleSelection: true,
            onCompletion: importGames
        )
        .dropDestination(for: URL.self) { urls, _ in
            importGames(.success(urls))
            return true
        }
        .alert("Couldn't add that", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.title ?? "")?",
            isPresented: .constant(pendingDeletion != nil),
            titleVisibility: .visible
        ) {
            Button("Delete Game and Saves", role: .destructive) {
                if let pendingDeletion { library.delete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The battery save and all save states go with it. This can't be undone.")
        }
    }

    private var shelf: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.games) { entry in
                    GameTile(entry: entry, cover: library.cover(for: entry))
                        .onTapGesture { play(entry) }
                        .contextMenu {
                            Button("Play", systemImage: "play.fill") { play(entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = entry
                            }
                        }
                }
            }
            .padding(20)
        }
    }

    private func importGames(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            do {
                try library.importGame(from: url)
            } catch {
                importError = (error as? LocalizedError)?.errorDescription
                    ?? "\(url.lastPathComponent) isn't a Game Boy ROM."
            }
        }
    }

    private var romTypes: [UTType] {
        let known = ["gb", "gbc"].compactMap { UTType(filenameExtension: $0) }
        // Nothing on the system declares what a .gb file is, so `.data` has to
        // be accepted and the header check does the rejecting.
        return known.isEmpty ? [.data] : known + [.data]
    }
}

// MARK: - Tile

private struct GameTile: View {
    let entry: GameEntry
    let cover: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.12))

                if let cover {
                    // The last frame of the last session, which says more about
                    // where you are than box art would.
                    Image(decorative: cover, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: entry.supportsColor ? "gamecontroller.fill" : "gamecontroller")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(160.0 / 144.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }

            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)

            Text(entry.playedDescription ?? entry.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Empty state

private struct EmptyShelf: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No games yet")
                .font(.title2.weight(.semibold))

            Text("Add a Game Boy ROM, or drop one here.\nIt's copied in, so the original can move or go.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Add Game…", action: add)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

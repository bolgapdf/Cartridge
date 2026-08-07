//
//  LibraryView.swift
//  Cartridge
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// The shelf. Every game the app has been given, most recently played first.
///
/// Laid out as a channel grid, which is the arrangement the Wii got right: one
/// tile per thing, all the same size, the picture doing the identifying. A list
/// of filenames is faster to build and worse at the only job the screen has,
/// which is letting you find a game without reading.
struct LibraryView: View {
    let library: GameLibrary
    let play: (GameEntry) -> Void

    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingDeletion: GameEntry?
    @State private var coverTarget: GameEntry?
    @State private var isShowingSettings = false
    @ThemeSetting private var theme
    #if os(iOS)
    @State private var pickedPhoto: PhotosPickerItem?
    #endif

    /// 150 rather than 168, which is the difference between two columns on a
    /// phone and one. A single column of tiles is a list wearing a costume.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 18)]

    var body: some View {
        ZStack {
            theme.shell.gradient.ignoresSafeArea()

            if library.games.isEmpty {
                EmptyShelf { isImporting = true }
            } else {
                shelf
            }
        }
        .navigationTitle("Cartridge")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Appearance", systemImage: "paintpalette") { isShowingSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Game", systemImage: "plus") { isImporting = true }
            }
        }
        .sheet(isPresented: $isShowingSettings) { AppearanceView() }
        .preferredColorScheme(theme.shell.scheme)
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
        .modifier(CoverPicker(library: library, target: $coverTarget))
    }

    private var shelf: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(library.games) { entry in
                    GameTile(entry: entry, cover: library.cover(for: entry), shell: theme.shell) {
                        play(entry)
                    }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { play(entry) }
                        Divider()
                        Button("Choose Artwork…", systemImage: "photo") { coverTarget = entry }
                        if entry.hasCustomCover {
                            Button("Use Screenshot Instead", systemImage: "arrow.uturn.backward") {
                                library.clearCustomCover(for: entry)
                            }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDeletion = entry
                        }
                    }
                }
            }
            .padding(22)
        }
        .scrollContentBackground(.hidden)
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
    let shell: ShellTheme
    let play: () -> Void

    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 0) {
            artwork
            label
        }
        .background {
            if shell.frosted {
                // Frosted rather than tinted, so the gradient behind actually
                // shows through the card the way a clear shell shows its board.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(shell.card)
                    }
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(shell.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(shell.border)
        }
        .shadow(color: .black.opacity(shell.dark ? 0.5 : 0.14), radius: 10, y: 4)
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(.spring(duration: 0.22), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A press that tracks the finger, so a tile visibly responds before the
        // game has loaded — which on a 2 MB cartridge is long enough to notice.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { value in
                    isPressed = false
                    let travel = hypot(value.translation.width, value.translation.height)
                    if travel < 12 { play() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(.isButton)
    }

    private var artwork: some View {
        ZStack {
            Rectangle().fill(shell.dark ? Color(white: 0.10) : Color.black.opacity(0.06))

            if let cover {
                Image(decorative: cover, scale: 1)
                    // Game screenshots are 160×144 shown at three times that, so
                    // smoothing them would undo the point.
                    .interpolation(entry.hasCustomCover ? .high : .none)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(160.0 / 144.0, contentMode: .fit)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if entry.supportsColor {
                ColorBadge()
                    .padding(7)
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Text(entry.playedDescription ?? entry.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }
}

/// The little rainbow the Color cartridges carried, which is exactly how you
/// told them apart on a shelf.
private struct ColorBadge: View {
    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                    center: .center
                )
            )
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
    }
}

// MARK: - Empty state

private struct EmptyShelf: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
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

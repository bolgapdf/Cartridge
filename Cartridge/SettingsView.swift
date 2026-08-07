//
//  SettingsView.swift
//  Cartridge
//

import SwiftUI

/// Appearance, and the one behaviour worth choosing.
///
/// The themes are shown as swatches rather than a list of names, because the
/// whole subject is what something looks like and a word for a colour is a
/// worse description of it than the colour.
struct SettingsView: View {
    let library: GameLibrary

    @AppStorage("shellTheme") private var shellID = ShellTheme.gameBoy.id
    @AppStorage("buttonTheme") private var buttonID = ButtonTheme.classic.id
    @AppStorage("autoResume") private var autoResume = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        // The Mac gets its own chrome. A `NavigationStack` in a sheet put its
        // toolbar somewhere that overlapped the last row, and Form's default
        // Mac style is a two-column layout that pushed the section labels off
        // the left edge of the sheet entirely.
        VStack(spacing: 0) {
            Text("Settings")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            form

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 640)
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
                Section {
                    LabeledContent("iCloud") {
                        Text(library.isUsingCloud ? "Syncing"
                             : CloudStorage.isSignedIn ? "Not set up" : "Signed out")
                            .foregroundStyle(library.isUsingCloud ? .green : .secondary)
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text(library.isUsingCloud
                         ? "Games, saves and save states are shared with your other devices. A save changed in two places at once keeps both — the newer one stays live and the other is kept beside it."
                         : "Everything is stored on this device only.")
                }

                Section {
                    Toggle("Resume Where You Left Off", isOn: $autoResume)
                        .onChange(of: autoResume) { _, enabled in
                            // Off has to mean off. A state kept from whenever
                            // this was last switched off would resurface the
                            // next time it's switched on, which reads as the
                            // app losing your progress rather than keeping it.
                            if !enabled { library.clearAutoStates() }
                        }
                } header: {
                    Text("Saving")
                } footer: {
                    Text(autoResume
                         ? "Leaving a game saves exactly where you are, and opening it again puts you back there. Your in-game saves are kept either way."
                         : "Leaving a game starts it from the title screen next time, like turning the console off. Only your in-game saves are kept.")
                }

                Section("Shelf") {
                    ForEach(ShellTheme.all) { theme in
                        row(name: theme.name, selected: theme.id == shellID) {
                            ShellSwatch(theme: theme)
                        } select: {
                            shellID = theme.id
                        }
                    }
                }

                Section("Buttons") {
                    ForEach(ButtonTheme.all) { theme in
                        row(name: theme.name, selected: theme.id == buttonID) {
                            ButtonSwatch(theme: theme)
                        } select: {
                            buttonID = theme.id
                        }
                    }
                }
            }
        // Grouped explicitly. On the Mac, Form defaults to a column layout
        // that reserves the left side for labels — which is right for a pane
        // full of fields and wrong for one that's mostly rows carrying their
        // own contents.
        .formStyle(.grouped)
    }

    private func row<Swatch: View>(
        name: String,
        selected: Bool,
        @ViewBuilder swatch: () -> Swatch,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 14) {
                swatch()
                Text(name)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swatches

private struct ShellSwatch: View {
    let theme: ShellTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.gradient)
            .overlay {
                // A miniature of the tile it produces, so the swatch shows the
                // arrangement rather than only the background colour.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(theme.border)
                    }
                    .padding(9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.15))
            }
            .frame(width: 46, height: 34)
    }
}

private struct ButtonSwatch: View {
    let theme: ButtonTheme

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.pad)
                .frame(width: 14, height: 14)
            Circle()
                .fill(theme.face)
                .frame(width: 14, height: 14)
            Capsule()
                .fill(theme.pill)
                .frame(width: 16, height: 8)
        }
        .padding(6)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(width: 46, height: 34)
    }
}

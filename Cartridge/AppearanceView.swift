//
//  AppearanceView.swift
//  Cartridge
//

import SwiftUI

/// Picks the shell and the buttons.
///
/// Shown as swatches rather than a list of names, because the whole subject is
/// what something looks like and a word for a colour is a worse description of
/// it than the colour.
struct AppearanceView: View {
    @AppStorage("shellTheme") private var shellID = ShellTheme.gameBoy.id
    @AppStorage("buttonTheme") private var buttonID = ButtonTheme.classic.id
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("Appearance")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
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

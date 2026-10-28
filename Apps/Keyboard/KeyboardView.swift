import SwiftUI
import WispenCore

/// Wispen keyboard: a full QWERTY keyboard with a toolbar (style, suggestions, ✨ command, 🎤 mic).
/// While Wispen is listening or writing, a voice panel replaces the keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        let palette = KeyPalette.make(model.theme)
        ZStack(alignment: .topTrailing) {
            ThemeBackground(palette: palette, effects: model.effects)
            VStack(spacing: 0) {
                Toolbar(model: model)
                    .frame(height: 44)
                Group {
                    if model.showsVoicePanel {
                        VoicePanel(model: model)
                    } else if model.showStyles {
                        StylesPanel(model: model)
                    } else if model.showEmoji {
                        EmojiPanel(model: model)
                    } else {
                        KeysView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            EffectsLayer(effects: model.effects)
                .allowsHitTesting(false)
            ComboBadge(effects: model.effects)
                .padding(.top, 48)
                .padding(.trailing, 10)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: KeyEffectsEngine.space)
        .environment(\.keyPalette, palette)
        .onChange(of: model.isRecording) {
            if model.isRecording { model.effects.startAmbient() } else { model.effects.stopAmbient() }
        }
    }
}

// MARK: Toolbar

private struct Toolbar: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.keyPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Button { model.showStyles.toggle() } label: {
                Text(model.style.emoji)
                    .font(.system(size: 18))
                    .frame(width: 38, height: 34)
                    .background(model.showStyles ? palette.accent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Style: \(model.style.name)")

            middle
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { model.commandTapped() } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.hasSelection ? palette.accent : palette.text)
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.hasSelection ? "Edit selection by voice" : "Write by voice")

            Button { model.micTapped() } label: {
                ZStack {
                    Circle().fill(model.isRecording ? Color.red : palette.accent).frame(width: 36, height: 36)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.isRecording ? .white : palette.accentText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isRecording ? "Stop dictation" : "Dictate")
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var middle: some View {
        if let pending = model.pendingInsert {
            Button { model.insertPending() } label: {
                Label("Insert “\(pending.prefix(28))\(pending.count > 28 ? "…" : "")”", systemImage: "text.insert")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else if let message = model.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.orange)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        } else if model.canUndo && model.currentWord.isEmpty {
            Button { model.undo() } label: {
                Label("Undo dictation", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.text)
            }
            .buttonStyle(.plain)
        } else if let snippet = model.shortcutSuggestion {
            Button { model.pickShortcut(snippet) } label: {
                Label(snippet.expansion.replacingOccurrences(of: "\n", with: " "), systemImage: "text.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Insert \(snippet.expansion)")
        } else if !model.suggestions.isEmpty || !model.emojiSuggestions.isEmpty {
            HStack(spacing: 0) {
                suggestion("“\(model.currentWord)”", value: model.currentWord)
                // With emoji there's room for one word suggestion.
                ForEach(model.suggestions.prefix(model.emojiSuggestions.isEmpty ? 2 : 1), id: \.self) { s in
                    Divider().frame(height: 22)
                    suggestion(s, value: s)
                }
                ForEach(model.emojiSuggestions, id: \.self) { e in
                    Divider().frame(height: 22)
                    Button { model.pickEmoji(e) } label: {
                        Text(e)
                            .font(.system(size: 24))
                            .frame(width: 42)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text(model.hasSelection ? "Tap ✨ or 🎤 to edit the selection by voice" : "\(model.style.name) · tap 🎤 to dictate")
                .font(.caption)
                .foregroundStyle(palette.text.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func suggestion(_ title: String, value: String) -> some View {
        Button { model.pick(value) } label: {
            Text(title)
                .font(.system(size: 16, weight: value == model.autocorrectPreview ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Voice panel

private struct VoicePanel: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.keyPalette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(palette.text.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack {
                Button { model.cancel() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: 20))
                        Text("Cancel").font(.caption2)
                    }
                    .frame(width: 70, height: 56)
                    .background(palette.mod.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(palette.text)
                }
                .buttonStyle(.plain)
                .opacity(model.isRecording || model.waitingForApp ? 1 : 0)

                Spacer()

                Button { model.micTapped() } label: {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color.red : palette.accent)
                            .frame(width: 96, height: 96)
                            .shadow(color: (model.isRecording ? Color.red : palette.accent).opacity(0.35), radius: 10, y: 4)
                        if model.isRecording {
                            PulsingBars()
                        } else {
                            ProgressView().tint(palette.accentText).scaleEffect(1.4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.isRecording)

                Spacer()

                VStack(spacing: 4) {
                    Text(model.style.emoji).font(.system(size: 22))
                    Text(model.state.mode == .command ? "Command" : model.style.name).font(.caption2)
                }
                .frame(width: 70, height: 56)
                .foregroundStyle(palette.text.opacity(0.6))
            }
            .padding(.horizontal, 20)
        }
    }

    private var statusText: String {
        switch model.state.phase {
        case .recording:
            return model.state.mode == .command ? "Say what to do with the text… tap to finish" : "Listening… tap to finish"
        case .transcribing: return model.state.message ?? "Transcribing…"
        case .polishing: return model.state.mode == .command ? "Rewriting…" : "Polishing…"
        default: return "Starting Wispen…"
        }
    }
}

// MARK: Styles panel

private struct StylesPanel: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.keyPalette) private var palette

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(model.styles) { style in
                    Button { model.selectStyle(style.id) } label: {
                        VStack(spacing: 2) {
                            Text(style.emoji).font(.system(size: 22))
                            Text(style.name).font(.footnote.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(model.styleID == style.id ? palette.accent.opacity(0.25) : palette.key,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(model.styleID == style.id ? palette.accent : palette.text)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }
}

// MARK: Emoji panel

/// Every emoji in a sideways-scrolling grid, with Frequently Used first, like the system keyboard.
/// Only the emoji on screen are drawn.
private struct EmojiPanel: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.keyPalette) private var palette
    /// The first emoji at the left edge, as "section-index"; setting it jumps to a section.
    @State private var position: String?

    /// The catalog's groups, prepared once.
    private static let groupSections: [EmojiSection] = EmojiCatalog.shared.groups.enumerated().map { i, g in
        EmojiSection(id: "g\(i)", symbol: g.symbol, name: g.name, emoji: g.emoji.map(\.character))
    }

    private struct EmojiSection: Identifiable {
        let id: String
        let symbol: String
        let name: String
        let emoji: [String]
    }

    private var sections: [EmojiSection] {
        var out: [EmojiSection] = []
        if !model.recentEmoji.isEmpty {
            out.append(EmojiSection(id: "r", symbol: "clock", name: "Frequently used", emoji: model.recentEmoji))
        }
        return out + Self.groupSections
    }

    private var currentSection: String {
        position.flatMap { $0.split(separator: "-").first.map(String.init) } ?? sections.first?.id ?? ""
    }

    var body: some View {
        let sections = sections
        VStack(spacing: 0) {
            GeometryReader { geo in
                let cell = max(28, (geo.size.height - 22) / 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text((sections.first { $0.id == currentSection }?.name ?? "").uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.text.opacity(0.5))
                        .padding(.leading, 10)
                        .frame(height: 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 5), spacing: 0) {
                            ForEach(sections) { section in
                                ForEach(Array(section.emoji.enumerated()), id: \.offset) { i, e in
                                    Button { model.insertEmoji(e) } label: {
                                        Text(e)
                                            .font(.system(size: cell * 0.78))
                                            .frame(width: cell * 1.12, height: cell)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id("\(section.id)-\(i)")
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 6)
                    }
                    .scrollPosition(id: $position, anchor: .leading)
                }
            }

            HStack(spacing: 0) {
                Button { model.showEmoji = false } label: {
                    Text("ABC").font(palette.font(15)).foregroundStyle(palette.text)
                        .frame(width: 48, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Letters")

                ForEach(sections) { section in
                    Button { position = "\(section.id)-0" } label: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(currentSection == section.id ? palette.accent : palette.text.opacity(0.55))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.name)
                }

                RepeatingDeleteButton(model: model)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }
}

/// Delete for the emoji panel: tap to delete one, hold to keep deleting.
private struct RepeatingDeleteButton: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.keyPalette) private var palette
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: timer == nil ? "delete.left" : "delete.left.fill")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(palette.text)
            .frame(width: 48, height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        model.deleteBackward()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            Task { @MainActor in
                                guard timer != nil else { return }
                                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                    Task { @MainActor in model.deleteBackward() }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.deleteBackward() }
    }
}

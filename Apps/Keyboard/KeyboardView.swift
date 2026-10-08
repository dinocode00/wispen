import SwiftUI
import WispenCore

/// Wispen keyboard: a full QWERTY keyboard with a toolbar (style, suggestions, ✨ command, 🎤 mic).
/// While Wispen is listening or writing, a voice panel replaces the keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let globeKey: GlobeKey

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
                    } else {
                        KeysView(model: model, globeKey: globeKey)
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
        } else if !model.suggestions.isEmpty {
            HStack(spacing: 0) {
                suggestion("“\(model.currentWord)”", value: model.currentWord)
                ForEach(model.suggestions, id: \.self) { s in
                    Divider().frame(height: 22)
                    suggestion(s, value: s)
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
                .font(.system(size: 16))
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

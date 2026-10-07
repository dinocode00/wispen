import SwiftUI
import WispenCore

/// Wispen keyboard: a full QWERTY keyboard with a toolbar (style, suggestions, ✨ command, 🎤 mic).
/// While Wispen is listening or writing, a voice panel replaces the keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let globeKey: GlobeKey

    var body: some View {
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
    }
}

// MARK: Toolbar

private struct Toolbar: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.showStyles.toggle() } label: {
                Text(model.style.emoji)
                    .font(.system(size: 18))
                    .frame(width: 38, height: 34)
                    .background(model.showStyles ? KeyColors.accent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Style: \(model.style.name)")

            middle
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { model.commandTapped() } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.hasSelection ? KeyColors.accent : Color.primary)
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.hasSelection ? "Edit selection by voice" : "Write by voice")

            Button { model.micTapped() } label: {
                ZStack {
                    Circle().fill(model.isRecording ? Color.red : KeyColors.accent).frame(width: 36, height: 36)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isRecording ? "Stop dictation" : "Dictate")
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var middle: some View {
        if let message = model.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.orange)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        } else if model.canUndo && model.currentWord.isEmpty {
            Button { model.undo() } label: {
                Label("Undo dictation", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func suggestion(_ title: String, value: String) -> some View {
        Button { model.pick(value) } label: {
            Text(title)
                .font(.system(size: 16))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Voice panel

private struct VoicePanel: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack {
                Button { model.cancel() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: 20))
                        Text("Cancel").font(.caption2)
                    }
                    .frame(width: 70, height: 56)
                    .background(KeyColors.function.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .opacity(model.isRecording || model.waitingForApp ? 1 : 0)

                Spacer()

                Button { model.micTapped() } label: {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color.red : KeyColors.accent)
                            .frame(width: 96, height: 96)
                            .shadow(color: (model.isRecording ? Color.red : KeyColors.accent).opacity(0.35), radius: 10, y: 4)
                        if model.isRecording {
                            PulsingBars()
                        } else {
                            ProgressView().tint(.white).scaleEffect(1.4)
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
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }

    private var statusText: String {
        switch model.state.phase {
        case .recording:
            return model.state.mode == .command ? "Say what to do with the text… tap to finish" : "Listening… tap to finish"
        case .transcribing: return "Transcribing…"
        case .polishing: return model.state.mode == .command ? "Rewriting…" : "Polishing…"
        default: return "Starting Wispen…"
        }
    }
}

// MARK: Styles panel

private struct StylesPanel: View {
    @ObservedObject var model: KeyboardModel

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
                        .background(model.styleID == style.id ? KeyColors.accent.opacity(0.25) : KeyColors.character,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(model.styleID == style.id ? KeyColors.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }
}

/// Animated bars shown while recording (the keyboard doesn't get live audio levels).
struct PulsingBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    let h = 10 + 22 * abs(sin(t * 3 + Double(i) * 0.9))
                    Capsule().fill(.white).frame(width: 5, height: h)
                }
            }
        }
    }
}

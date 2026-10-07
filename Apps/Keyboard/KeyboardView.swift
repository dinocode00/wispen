import SwiftUI
import WispenCore

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let globeKey: GlobeKey

    private let accent = Color(red: 0.42, green: 0.36, blue: 0.95)

    var body: some View {
        VStack(spacing: 8) {
            styleBar
            statusLine
            HStack(alignment: .center, spacing: 0) {
                if model.isRecording {
                    sideButton(icon: "xmark", label: "Cancel") { model.cancel() }
                } else {
                    sideButton(icon: "wand.and.stars", label: model.hasSelection ? "Edit" : "Write") { model.commandTapped() }
                        .opacity(model.isWorking ? 0.3 : 1)
                }
                Spacer()
                micButton
                Spacer()
                DeleteKey { model.deleteBackward() }
            }
            .padding(.horizontal, 18)
            bottomRow
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Pieces

    private var styleBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.styles) { style in
                    Button { model.selectStyle(style.id) } label: {
                        Text("\(style.emoji) \(style.name)")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(model.styleID == style.id ? accent.opacity(0.2) : Color(uiColor: .secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(model.styleID == style.id ? accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                if model.canUndo {
                    Button { model.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(model.message != nil ? Color.orange : Color.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(height: 30)
    }

    private var statusText: String {
        if let m = model.message { return m }
        switch model.state.phase {
        case .recording: return model.state.mode == .command ? "Say what to do with the text… tap to finish" : "Listening… tap to finish"
        case .transcribing: return "Transcribing…"
        case .polishing: return model.state.mode == .command ? "Rewriting…" : "Polishing…"
        case .error: return model.state.message ?? "Something went wrong"
        case .ready, .inactive:
            if model.waitingForApp { return "Starting…" }
            if model.hasSelection { return "Tap the mic to edit the selected text by voice" }
            return model.state.phase == .ready ? "Tap the mic and talk" : "Tap the mic to start Wispen"
        }
    }

    private var micButton: some View {
        Button { model.micTapped() } label: {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.red : accent)
                    .frame(width: 92, height: 92)
                    .shadow(color: (model.isRecording ? Color.red : accent).opacity(0.35), radius: 10, y: 4)
                if model.isRecording {
                    PulsingBars()
                } else if model.isWorking || model.waitingForApp {
                    ProgressView().tint(.white).scaleEffect(1.3)
                } else {
                    Image(systemName: model.hasSelection ? "wand.and.stars" : "mic.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isRecording ? "Stop dictation" : "Start dictation")
    }

    private func sideButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20))
                Text(label).font(.caption2)
            }
            .frame(width: 64, height: 54)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.needsGlobeKey {
                globeKey.frame(width: 44, height: 42)
            }
            key(".") { model.insert(".") }
            key(",") { model.insert(",") }
            key("?") { model.insert("?") }
            Button { model.insert(" ") } label: {
                Text("space").font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            Button { model.insert("\n") } label: {
                Image(systemName: "return")
                    .frame(width: 58, height: 42)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.title3)
                .frame(width: 34, height: 42)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Backspace that repeats while held.
struct DeleteKey: View {
    var action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "delete.left").font(.system(size: 20))
            Text("Delete").font(.caption2)
        }
        .frame(width: 64, height: 54)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
            if pressing {
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                    Task { @MainActor in
                        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                            Task { @MainActor in action() }
                        }
                    }
                }
            } else {
                timer?.invalidate()
                timer = nil
            }
        }, perform: {})
        .accessibilityLabel("Delete")
        .accessibilityAddTraits(.isButton)
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

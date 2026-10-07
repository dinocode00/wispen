import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WispenWidgetBundle: WidgetBundle {
    var body: some Widget {
        WispenLiveActivity()
    }
}

private let accent = Color(red: 0.42, green: 0.36, blue: 0.95)

/// Flow session and meeting status in the Dynamic Island and on the Lock Screen.
struct WispenLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WispenActivityAttributes.self) { context in
            LockScreenView(state: context.state, kind: context.attributes.kind)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let kind = context.attributes.kind
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase)
                        .font(.title2)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingStatus(state: state)
                        .font(.title3.monospacedDigit())
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(for: state.phase))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Subtitle(state: state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ActionButton(kind: kind, phase: state.phase)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                PhaseIcon(phase: state.phase)
            } compactTrailing: {
                TrailingStatus(state: state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 46)
            } minimal: {
                PhaseIcon(phase: state.phase)
            }
            .keylineTint(color(for: state.phase))
        }
    }
}

func title(for phase: WispenActivityAttributes.Phase) -> String {
    switch phase {
    case .ready: return "Wispen is ready"
    case .recording: return "Listening…"
    case .transcribing: return "Transcribing…"
    case .polishing: return "Polishing…"
    case .meetingRecording: return "Recording meeting"
    case .meetingSummarizing: return "Writing recap…"
    }
}

func color(for phase: WispenActivityAttributes.Phase) -> Color {
    switch phase {
    case .recording, .meetingRecording: return .red
    case .transcribing, .polishing, .meetingSummarizing: return .orange
    case .ready: return accent
    }
}

struct PhaseIcon: View {
    let phase: WispenActivityAttributes.Phase

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color(for: phase))
            .symbolEffect(.pulse, isActive: phase == .recording || phase == .meetingRecording)
    }

    private var symbol: String {
        switch phase {
        case .ready: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .transcribing, .polishing: return "sparkles"
        case .meetingRecording: return "record.circle"
        case .meetingSummarizing: return "doc.text.magnifyingglass"
        }
    }
}

/// Live timer while recording; otherwise a short status.
struct TrailingStatus: View {
    let state: WispenActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording, .meetingRecording:
            if let start = state.startedAt {
                Text(start, style: .timer).multilineTextAlignment(.trailing).foregroundStyle(.red)
            }
        case .meetingSummarizing:
            if let p = state.progress { Text("\(Int(p * 100))%").foregroundStyle(.orange) }
        case .ready:
            Image(systemName: "mic.fill").foregroundStyle(accent)
        case .transcribing, .polishing:
            Image(systemName: "ellipsis").foregroundStyle(.orange)
        }
    }
}

struct Subtitle: View {
    let state: WispenActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .ready:
            if let ends = state.sessionEndsAt {
                Text("Tap 🎤 on the Wispen keyboard · ends \(ends, style: .time) if idle")
            } else {
                Text("Tap 🎤 on the Wispen keyboard")
            }
        case .recording: Text("Tap the mic again when you're done")
        case .transcribing, .polishing: Text("On-device, private")
        case .meetingRecording: Text("Transcribing on-device · audio is never saved")
        case .meetingSummarizing: Text(state.detail ?? "Summarizing on-device")
        }
    }
}

struct ActionButton: View {
    let kind: WispenActivityAttributes.Kind
    let phase: WispenActivityAttributes.Phase

    var body: some View {
        switch (kind, phase) {
        case (.flowSession, .ready), (.flowSession, .recording):
            Button(intent: EndFlowSessionIntent()) {
                Label("End", systemImage: "xmark")
            }
            .tint(.gray)
        case (.meeting, .meetingRecording):
            Button(intent: StopMeetingIntent()) {
                Label("Stop & summarize", systemImage: "stop.fill")
            }
            .tint(.red)
        default:
            EmptyView()
        }
    }
}

struct LockScreenView: View {
    let state: WispenActivityAttributes.ContentState
    let kind: WispenActivityAttributes.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color(for: state.phase).opacity(0.25)).frame(width: 42, height: 42)
                    PhaseIcon(phase: state.phase).font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title(for: state.phase)).font(.headline).foregroundStyle(.white)
                        Spacer()
                        TrailingStatus(state: state).font(.headline.monospacedDigit())
                    }
                    Subtitle(state: state).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            if state.phase == .meetingSummarizing, let p = state.progress {
                ProgressView(value: p).tint(.orange)
            }
            HStack {
                Spacer()
                ActionButton(kind: kind, phase: state.phase)
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

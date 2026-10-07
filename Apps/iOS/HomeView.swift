import SwiftUI
import UIKit
import WispenCore

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var flow: FlowSessionController

    var body: some View {
        List {
            sessionSection
            TryItSection(engine: flow.engine)
            setupSection
        }
        .navigationTitle("Wispen")
    }

    private var sessionSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.15)).frame(width: 46, height: 46)
                    if flow.state.phase == .recording {
                        EngineMeter(engine: flow.engine, bars: 4, color: statusColor)
                    } else {
                        Image(systemName: flow.isActive ? "waveform" : "moon.zzz").foregroundStyle(statusColor)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(flow.isActive ? "End" : "Start") {
                    if flow.isActive { flow.endSession() } else { Task { await flow.startSession() } }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
            Stepper("End session after \(app.settings.sessionTimeoutMinutes) idle min",
                    value: $app.settings.sessionTimeoutMinutes, in: 1...120, step: app.settings.sessionTimeoutMinutes < 10 ? 1 : 5)
                .font(.callout)
        } header: {
            Text("Flow session")
        } footer: {
            Text("While a session is active, the Wispen keyboard can dictate into any app. iOS shows an orange mic dot, but Wispen only records while you're dictating.")
        }
    }

    private var statusColor: Color {
        switch flow.state.phase {
        case .recording: return .red
        case .transcribing, .polishing: return .orange
        case .ready: return .green
        case .error: return .red
        case .inactive: return .secondary
        }
    }

    private var statusTitle: String {
        switch flow.state.phase {
        case .inactive: return "Session off"
        case .ready: return "Ready to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        case .error: return "Error"
        }
    }

    private var statusDetail: String {
        if flow.state.phase == .error { return flow.state.message ?? "" }
        if let ends = flow.state.sessionEndsAt, flow.isActive {
            return "Ends \(ends.formatted(date: .omitted, time: .shortened)) if idle"
        }
        return "Tap the mic on the Wispen keyboard to start one"
    }

    private var setupSection: some View {
        Section {
            SetupRow(done: app.speechModel.isReady, title: "Speech model",
                     detail: app.speechModel.label) {
                Task { await app.prepareSpeechModel() }
            }
            let ai = GeneratorFactory.appleIntelligenceStatus()
            SetupRow(done: ai.ready, title: "Apple Intelligence", detail: ai.message, action: nil)
            SetupRow(done: false, title: "Add the Wispen keyboard",
                     detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard › Wispen. Then tap Wispen and turn on Allow Full Access (needed to talk to this app — nothing leaves your phone).") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            SetupRow(done: false, title: "Use it",
                     detail: "In any app, hold 🌐 on the keyboard and pick Wispen. Tap the mic, talk, tap again. Select text first to edit it by voice.", action: nil)
        } header: {
            Text("Setup")
        }
    }
}

struct SetupRow: View {
    var done: Bool
    var title: String
    var detail: String
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action, !done {
                Button("Open", action: action).font(.caption).buttonStyle(.bordered)
            }
        }
    }
}

/// Dictate right inside Wispen — handy for notes and for testing styles.
struct TryItSection: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var flow: FlowSessionController
    @ObservedObject var engine: DictationEngine
    @State private var text = ""
    @State private var styleID = DictationStyle.polished.id
    @State private var busy = false

    private var recording: Bool { engine.phase == .recording }

    var body: some View {
        Section {
            TextEditor(text: $text)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Tap the mic and say something like “um so I think we should meet tuesday no wait wednesday”")
                            .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            HStack {
                Picker("Style", selection: $styleID) {
                    ForEach(app.allStyles) { Text("\($0.emoji) \($0.name)").tag($0.id) }
                }
                .labelsHidden()
                Spacer()
                if !text.isEmpty {
                    Button { Pasteboard.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    Button { text = "" } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                Button {
                    toggle()
                } label: {
                    ZStack {
                        Circle().fill(recording ? Color.red : Color.wispenAccent).frame(width: 44, height: 44)
                        if engine.phase == .transcribing || engine.phase == .polishing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: recording ? "stop.fill" : "mic.fill").foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy && !recording)
                .disabled(engine.phase == .transcribing || engine.phase == .polishing)
            }
            if let error = flow.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Try it")
        }
        .onAppear { styleID = app.settings.defaultStyleID }
    }

    private func toggle() {
        Task {
            if recording {
                busy = true
                if let result = await flow.dictateInApp(start: false, styleID: styleID) {
                    text = text.isEmpty ? result : text + InsertionFormatter.prepare(result, before: text)
                }
                busy = false
            } else {
                busy = true
                _ = await flow.dictateInApp(start: true, styleID: styleID)
                busy = false
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            SharedSettingsSections()
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
        }
        .navigationTitle("Settings")
    }
}

/// Level meter that observes the engine directly (so it redraws as the level changes).
struct EngineMeter: View {
    @ObservedObject var engine: DictationEngine
    var bars = 5
    var color: Color = .wispenAccent

    var body: some View {
        LevelMeter(level: engine.level, bars: bars, color: color)
    }
}

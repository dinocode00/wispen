import SwiftUI
import UIKit
import WispenCore

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var flow: FlowSessionController
    /// Re-check keyboard setup each time you come back from Settings.
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = KeyboardSetup.current
    @State private var lastResult = FlowIPC.resultFile.load()

    var body: some View {
        List {
            sessionSection
            skipTheTripSection
            TryItSection(engine: flow.engine)
            setupSection
            lastDictationSection
        }
        .onAppear(perform: refreshChecks)
        .onChange(of: scenePhase) { if scenePhase == .active { refreshChecks() } }
        .onReceive(NotificationCenter.default.publisher(for: .wispenResultWritten)) { _ in refreshChecks() }
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
            Picker("Keep session on", selection: $app.settings.sessionTimeoutMinutes) {
                Text("5 idle minutes").tag(5)
                Text("15 idle minutes").tag(15)
                Text("1 idle hour").tag(60)
                Text("4 idle hours").tag(240)
                Text("Until I end it").tag(0)
            }
            .font(.callout)
        } header: {
            Text("Flow session")
        } footer: {
            Text("While a session is active, the Wispen keyboard can dictate into any app. iOS shows an orange mic dot, but Wispen only records while you're dictating. Locking your phone ends the session.")
        }
    }

    /// iOS only lets an app turn the mic on while it's on screen — except through these system
    /// buttons and automations, which can start Wispen in the background.
    private var skipTheTripSection: some View {
        Section {
            howTo("switch.2", "Control Center",
                  "Swipe down from the top-right › + › Add a Control › search “Wispen” › Start Wispen.")
            howTo("button.horizontal.top.press", "Action Button",
                  "Settings › Action Button › Controls › Start Wispen.")
            howTo("wand.and.rays", "Automatically, only while you're texting (recommended)",
                  "Shortcuts › Automation › + › App › choose Messages (and any others) › tick “Is Opened” › Run Immediately › Next › Start Wispen. Then make a second one with “Is Closed” › End Wispen. The mic is only on while you're in those apps.")
            howTo("mic", "Siri", "“Hey Siri, start Wispen.”")
        } header: {
            Text("Start without opening Wispen")
        } footer: {
            Text("iOS only lets an app turn on the microphone from the screen — that's why the keyboard sends you here when no session is running. These start a session in the background instead, so the keyboard mic just works. Wispen only records while you're dictating; the orange dot shows the session is ready.")
        }
    }

    private func howTo(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.wispenAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
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

    private func refreshChecks() {
        keyboard = KeyboardSetup.current
        lastResult = FlowIPC.resultFile.load()
    }

    private var setupSection: some View {
        Section {
            SetupRow(done: app.speechModel.isReady, title: "Speech model",
                     detail: app.speechModel.label) {
                Task { await app.prepareSpeechModel() }
            }
            let ai = GeneratorFactory.appleIntelligenceStatus()
            SetupRow(done: ai.ready, title: "Apple Intelligence", detail: ai.message, action: nil)
            SetupRow(done: keyboard == .ready, title: "Add the Wispen keyboard", detail: keyboard.detail) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            SetupRow(done: !app.history.isEmpty, title: "Use it",
                     detail: "In any app, hold 🌐 on the keyboard and pick Wispen. Tap the mic, talk, tap again. Select text first to edit it by voice.", action: nil)
        } header: {
            Text("Setup")
        }
    }

    /// The last keyboard dictation, so problems are visible (and easy to report).
    @ViewBuilder
    private var lastDictationSection: some View {
        if let result = lastResult {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.error == nil ? Color.green : Color.orange)
                        Text(result.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        Text("ago").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = result.error {
                        Text(error).font(.callout)
                    } else {
                        Text(result.text).font(.callout).lineLimit(4)
                    }
                }
            } header: {
                Text("Last keyboard dictation")
            }
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
            Section {
                NavigationLink { KeyboardLookView() } label: {
                    LabeledContent {
                        Text("\(app.settings.keyboardTheme.look.name) · \(app.settings.keyboardTheme.effect.name)")
                    } label: {
                        Label("Look & effects", systemImage: "paintpalette")
                    }
                }
                Toggle("Auto-correction", isOn: $app.settings.keyboardAutoCorrect)
                Toggle("Suggestions", isOn: $app.settings.keyboardSuggestions)
                Toggle("Auto-capitalization", isOn: $app.settings.keyboardAutoCapitalize)
                Toggle("“.” shortcut (double-tap space)", isOn: $app.settings.keyboardDoubleSpacePeriod)
                Toggle("Key click sounds", isOn: $app.settings.keyboardSounds)
            } header: {
                Text("Wispen keyboard")
            } footer: {
                Text("Changes apply the next time the keyboard opens. Key click sounds need Allow Full Access. Drag the space bar to move the cursor; backspace right after an autocorrection undoes it.")
            }
            Section {
                Toggle("Dynamic Island & Lock Screen", isOn: $app.settings.liveActivities)
                    .onChange(of: app.settings.liveActivities) {
                        if !app.settings.liveActivities {
                            LiveActivityController.shared.endFlow()
                            LiveActivityController.shared.endMeeting()
                        }
                    }
            } footer: {
                Text("Shows the flow session and meeting recordings in the Dynamic Island and on the Lock Screen, with buttons to end them.")
            }
            Section {
                Toggle("Identify speakers", isOn: $app.settings.meetingSpeakerLabels)
            } header: {
                Text("Meetings")
            } footer: {
                Text("Labels the transcript Speaker 1, Speaker 2… (tap a speaker in a transcript to name them). The audio is kept in a temporary file only until that's done, then deleted.")
            }
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

/// Is the Wispen keyboard added, and does it have Full Access?
enum KeyboardSetup {
    case notAdded, needsFullAccess, ready

    static var current: KeyboardSetup {
        let status = FlowIPC.keyboardStatusFile.load()
        if status?.hasFullAccess == true { return .ready }
        return (status != nil || isEnabledInSettings) ? .needsFullAccess : .notAdded
    }

    /// Whether Wispen appears in the user's list of keyboards.
    private static var isEnabledInSettings: Bool {
        let keyboardID = (Bundle.main.bundleIdentifier ?? "") + ".keyboard"
        let selector = NSSelectorFromString("identifier")
        return UITextInputMode.activeInputModes.contains { mode in
            mode.responds(to: selector) && (mode.value(forKey: "identifier") as? String) == keyboardID
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "Wispen keyboard is on with Full Access."
        case .needsFullAccess:
            return "Almost there: Keyboards › Wispen › turn on Allow Full Access. Then open the Wispen keyboard once (e.g. in Messages) — this turns green."
        case .notAdded:
            return "Tap Open › Keyboards › turn on Wispen and Allow Full Access. Then open the Wispen keyboard once (e.g. in Messages) — this turns green."
        }
    }
}

extension Notification.Name {
    /// Posted in-process when the flow session delivers a keyboard dictation result.
    static let wispenResultWritten = Notification.Name("wispenResultWritten")
}

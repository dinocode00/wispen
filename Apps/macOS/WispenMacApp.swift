import AppKit
import SwiftUI
import WispenCore

@main
struct WispenMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @StateObject private var controller = MacController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(app)
                .environmentObject(controller)
                .environmentObject(controller.recorder)
        } label: {
            MenuBarIcon(engine: controller.engine, recorder: controller.recorder)
        }
        .menuBarExtraStyle(.window)

        Window("Wispen", id: "main") {
            MacMainView()
                .environmentObject(app)
                .environmentObject(controller)
                .environmentObject(controller.recorder)
                .tint(.wispenAccent)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { MacController.shared.start() }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        if recorder.isRecording {
            Image(systemName: "record.circle")
        } else if engine.phase == .recording {
            Image(systemName: "waveform.circle.fill")
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var controller: MacController
    @EnvironmentObject var recorder: MeetingRecorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wispen").font(.headline)
                Spacer()
                Text(app.speechModel.isReady ? "Ready" : app.speechModel.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if !controller.hasAccessibility {
                Button {
                    TextInserter.requestAccessibility()
                } label: {
                    Label("Allow Accessibility so Wispen can type", systemImage: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hold **fn** and talk · double-tap for hands-free")
                Text("Hold **fn + control** to edit selected text")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Picker("Style", selection: $app.settings.defaultStyleID) {
                ForEach(app.allStyles) { Text("\($0.emoji) \($0.name)").tag($0.id) }
            }

            if let last = controller.lastResult {
                GroupBox {
                    Text(last).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                } label: {
                    HStack {
                        Text("Last dictation")
                        Spacer()
                        Button("Copy") { Pasteboard.copy(last) }.buttonStyle(.link)
                    }
                }
            }

            Divider()

            if recorder.isRecording {
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text("Meeting · \(formatDuration(recorder.elapsed))").monospacedDigit()
                    Spacer()
                    Button("Stop & summarize") { Task { await recorder.stop() } }
                }
            } else if let stage = recorder.recapStage {
                ProgressView(value: recorder.recapProgress) { Text(stage).font(.caption) }
            } else {
                Button {
                    Task {
                        await recorder.start(micLabel: controller.meetingMicLabel, extraSources: controller.meetingSources)
                    }
                } label: { Label("Record a meeting", systemImage: "record.circle") }
            }

            Divider()

            HStack {
                Button("Open Wispen") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct MacMainView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", meetings = "Meetings", dictionary = "Dictionary", snippets = "Snippets",
             styles = "Styles", history = "History"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .meetings: return "person.2.wave.2"
            case .dictionary: return "character.book.closed"
            case .snippets: return "text.badge.plus"
            case .styles: return "paintpalette"
            case .history: return "clock"
            }
        }
    }

    @EnvironmentObject var app: AppModel
    @EnvironmentObject var controller: MacController
    @State private var page: Page? = .general

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            NavigationStack {
                switch page ?? .general {
                case .general: MacGeneralView()
                case .meetings:
                    MeetingsView(extraSources: { controller.meetingSources }, micLabel: controller.meetingMicLabel)
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .styles: StylesView()
                case .history: HistoryView()
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.lastError ?? "") }
    }
}

struct MacGeneralView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var controller: MacController
    @State private var newBundleID = ""
    @State private var newStyleID = DictationStyle.casual.id

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    if controller.hasAccessibility {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { TextInserter.requestAccessibility() }
                    }
                }
                Text("Hold **fn** to dictate, double-tap **fn** for hands-free, **fn + control** for command mode. If fn opens the emoji picker, set System Settings › Keyboard › “Press 🌐 key to” › Do Nothing.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Hotkey") }

            SharedSettingsSections()

            Section {
                Toggle("Also capture system audio (the other people on a call)", isOn: $app.settings.meetingCaptureSystemAudio)
                Toggle("Identify speakers (Speaker 1, Speaker 2…)", isOn: $app.settings.meetingSpeakerLabels)
            } header: {
                Text("Meetings")
            } footer: {
                Text("Labels the transcript “Me” and “Others”. macOS asks for Screen & System Audio Recording permission the first time. Wear headphones for the cleanest transcript.")
            }

            Section {
                ForEach(appRules, id: \.0) { rule in
                    let (bundleID, styleID) = rule
                    HStack {
                        Text(bundleID).font(.callout.monospaced())
                        Spacer()
                        Text(app.style(id: styleID).emoji + " " + app.style(id: styleID).name)
                        if app.settings.appStyleOverrides[bundleID] != nil {
                            Button { app.settings.appStyleOverrides[bundleID] = nil } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("App bundle ID (e.g. com.tinyspeck.slackmacgap)", text: $newBundleID)
                    Picker("", selection: $newStyleID) {
                        ForEach(app.allStyles) { Text("\($0.emoji) \($0.name)").tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button("Add") {
                        app.settings.appStyleOverrides[newBundleID.trimmingCharacters(in: .whitespaces)] = newStyleID
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                    Text("Tip: this window is \(front). Find other apps' IDs in their Info.plist, or with `osascript -e 'id of app \"Slack\"'`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Styles per app")
            } footer: {
                Text("Wispen picks a style from the app you're typing in. Everything else uses the default style.")
            }

            Section {
                LibrarySyncRow()
            } header: { Text("Sync with iPhone") }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private var appRules: [(String, String)] {
        AppStyleRules.defaults.merging(app.settings.appStyleOverrides) { _, new in new }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}

struct LibrarySyncRow: View {
    @EnvironmentObject var app: AppModel
    @State private var importing = false
    @State private var exportURL: URL?

    var body: some View {
        HStack {
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share library file", systemImage: "square.and.arrow.up") }
            } else {
                Button("Export library…") { exportURL = try? app.exportLibraryFile() }
            }
            Button("Import library…") { importing = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                do { try app.importLibrary(from: url) } catch { app.lastError = "Import failed: \(error.localizedDescription)" }
            }
        }
    }
}

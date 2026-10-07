import SwiftUI
import WispenCore

@main
struct WispenApp: App {
    @StateObject private var app = AppModel.shared
    @StateObject private var flow = FlowSessionController(app: AppModel.shared)
    @StateObject private var recorder = MeetingRecorder(app: AppModel.shared)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(flow)
                .environmentObject(recorder)
                .tint(.wispenAccent)
                .onOpenURL { url in
                    if recorder.isRecording {
                        flow.reject(url: url, reason: "Wispen is recording a meeting. Stop it to dictate.")
                        return
                    }
                    flow.handle(url: url)
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        app.reload()
                        resumeUnfinishedRecaps()
                    }
                }
                .task { await app.prepareSpeechModel() }
        }
    }

    /// If the app was closed while a recap was being written, finish it now.
    private func resumeUnfinishedRecaps() {
        guard !recorder.isRecording else { return }
        for meeting in app.meetings where meeting.status == .summarizing || (meeting.status == .recording && !meeting.segments.isEmpty) {
            Task { await recorder.summarize(meetingID: meeting.id) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var flow: FlowSessionController
    @EnvironmentObject var recorder: MeetingRecorder

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Flow", systemImage: "waveform") }
            NavigationStack {
                MeetingsView(willStart: { flow.endSession() })
            }
            .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: $flow.showSwipeBackHint) { SwipeBackView() }
        .alert("Something went wrong", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
    }
}

/// Shown when the keyboard opened Wispen to start a session: tells you to swipe back.
struct SwipeBackView: View {
    @EnvironmentObject var flow: FlowSessionController

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Image(systemName: "arrow.uturn.backward")
                Text("Swipe right along the bottom edge, or tap ◀︎ at the top-left, to go back")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            Spacer()

            ZStack {
                Circle().fill(Color.wispenAccent.opacity(0.15)).frame(width: 180, height: 180)
                EngineMeter(engine: flow.engine, bars: 7).scaleEffect(2)
            }

            VStack(spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Text("Go back to your app and keep talking. Tap the Wispen mic again when you're done.\nFrom now on the keyboard works without coming here, until the session ends after \(flow.app.settings.sessionTimeoutMinutes) idle minutes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button("Stay in Wispen") { flow.showSwipeBackHint = false }
                .padding(.bottom, 30)
        }
        .onChange(of: flow.state.phase) {
            if flow.state.phase == .inactive { flow.showSwipeBackHint = false }
        }
    }

    private var title: String {
        switch flow.state.phase {
        case .recording: return "Listening…"
        case .transcribing, .polishing: return "Writing…"
        case .error: return flow.state.message ?? "Something went wrong"
        default: return "Wispen is ready"
        }
    }
}

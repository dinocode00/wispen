import AppKit
import Combine
import SwiftUI
import WispenCore

/// Glue for the Mac app: Fn key → record → transcribe → polish → paste into the focused app.
@MainActor
final class MacController: ObservableObject {
    static let shared = MacController()

    let app = AppModel.shared
    let engine: DictationEngine
    let recorder: MeetingRecorder
    private let hotkey = HotkeyMonitor()
    private let overlay: OverlayPanel

    @Published private(set) var hasAccessibility = TextInserter.hasAccessibility
    @Published private(set) var lastResult: String?
    @Published private(set) var status: String?

    private var mode: DictationMode = .dictation
    private var selectedText: String?
    private var targetApp: NSRunningApplication?
    /// A finish/cancel that arrived while `begin` was still copying the selection.
    private var isBeginning = false
    private var pendingEnd: HotkeyMonitor.Event?
    private var bag: Set<AnyCancellable> = []

    private init() {
        engine = DictationEngine(app: AppModel.shared)
        recorder = MeetingRecorder(app: AppModel.shared)
        overlay = OverlayPanel()
    }

    func start() {
        SpeakerReviewStore.purgeExpired()
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        hotkey.start()
        overlay.attach(engine: engine, controller: self)
        if !TextInserter.hasAccessibility { TextInserter.requestAccessibility() }
        Task {
            _ = await AudioCapture.requestPermission()
            await app.prepareSpeechModel()
        }
        // Re-check Accessibility periodically until granted (the user flips it in System Settings).
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.hasAccessibility else { return }
                self.hasAccessibility = TextInserter.hasAccessibility
            }
            .store(in: &bag)
    }

    // MARK: Hotkey

    private func handle(_ event: HotkeyMonitor.Event) {
        if isBeginning {
            // Still copying the selection: remember how this press ended and apply it afterwards.
            if case .begin = event { return }
            pendingEnd = event
            return
        }
        switch event {
        case .begin(let command):
            isBeginning = true // set synchronously so a quick release can't slip in before begin() runs
            Task { await begin(command: command) }
        case .finish: Task { await finish() }
        case .cancel: cancel()
        }
    }

    func begin(command: Bool) async {
        isBeginning = true
        guard engine.phase == .idle, !recorder.isRecording else {
            isBeginning = false
            pendingEnd = nil
            hotkey.reset()
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        mode = command ? .command : .dictation
        selectedText = nil
        if command { selectedText = await TextInserter.copySelection() }
        do {
            try engine.startRecording()
            status = nil
            overlay.show()
        } catch {
            hotkey.reset()
            flash(error.localizedDescription)
        }
        isBeginning = false
        if let pending = pendingEnd {
            pendingEnd = nil
            handle(pending)
        }
    }

    func finish() async {
        guard engine.phase == .recording else { return }
        let bundleID = targetApp?.bundleIdentifier
        let styleID = AppStyleRules.styleID(forBundleID: bundleID, settings: app.settings)
        let outcome = await engine.finish(mode: mode, styleID: styleID, selectedText: selectedText,
                                          appName: targetApp?.localizedName)
        hotkey.reset()
        if let error = outcome.error {
            flash(error)
            return
        }
        overlay.hide()
        lastResult = outcome.text
        guard TextInserter.hasAccessibility else {
            Pasteboard.copy(outcome.text)
            flash("Copied — allow Accessibility so Wispen can type for you.")
            return
        }
        // Make sure the text lands where you were typing.
        if let targetApp, targetApp != NSWorkspace.shared.frontmostApplication {
            _ = targetApp.activate(options: [])
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        TextInserter.paste(outcome.text)
    }

    func cancel() {
        engine.cancel()
        hotkey.reset()
        overlay.hide()
    }

    func toggleFromMenu() {
        if engine.phase == .recording {
            Task { await finish() }
        } else {
            Task { await begin(command: false) }
        }
    }

    private func flash(_ message: String) {
        status = message
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.engine.phase == .idle else { return }
            self.status = nil
            self.overlay.hide()
        }
    }

    // MARK: Meetings

    var meetingSources: [MeetingAudioSource] {
        app.settings.meetingCaptureSystemAudio ? [SystemAudioSource()] : []
    }

    var meetingMicLabel: String? {
        app.settings.meetingCaptureSystemAudio ? "Me" : nil
    }
}

/// The little floating pill at the bottom of the screen while you dictate.
final class OverlayPanel {
    private var panel: NSPanel?

    @MainActor
    func attach(engine: DictationEngine, controller: MacController) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 54),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: OverlayView(engine: engine, controller: controller))
        self.panel = panel
    }

    @MainActor
    func show() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 28))
        panel.orderFrontRegardless()
    }

    @MainActor
    func hide() {
        panel?.orderOut(nil)
    }
}

struct OverlayView: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject var controller: MacController

    var body: some View {
        HStack(spacing: 10) {
            switch engine.phase {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelMeter(level: engine.level, bars: 7, color: .white)
                Text("Listening").foregroundStyle(Color.white.opacity(0.8))
            case .transcribing, .polishing:
                ProgressView().controlSize(.small).tint(.white)
                Text(engine.phase == .transcribing ? "Transcribing" : "Polishing").foregroundStyle(Color.white.opacity(0.8))
            case .idle:
                Text(controller.status ?? "").foregroundStyle(.white).lineLimit(2)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.black.opacity(0.82), in: Capsule())
        .frame(width: 260, height: 54)
    }
}

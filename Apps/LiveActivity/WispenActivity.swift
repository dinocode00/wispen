import ActivityKit
import AppIntents
import Foundation

/// Shared by the Wispen app and the widget extension: what the Dynamic Island / Lock Screen shows.
struct WispenActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable {
        case flowSession
        case meeting
    }

    enum Phase: String, Codable, Hashable {
        case ready, recording, transcribing, polishing
        case meetingRecording, meetingSummarizing
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// When the current recording started (drives the live timer).
        var startedAt: Date?
        /// Flow session: when it ends if idle.
        var sessionEndsAt: Date?
        /// Meeting recap progress, 0…1.
        var progress: Double?
        var detail: String?
    }

    var kind: Kind
}

/// Actions the Live Activity buttons trigger. The app fills these in at launch; Live Activity intents
/// always run inside the app's process, so they're set when `perform()` runs.
@MainActor
enum WispenActivityActions {
    static var endFlowSession: (() -> Void)?
    /// Starts the flow session (mic ready for the keyboard) — set by the app.
    static var startFlowSession: (@MainActor () async -> Void)?
    static var stopMeeting: (() -> Void)?
}

struct EndFlowSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Wispen session"
    static let description = IntentDescription("Stops the background flow session and turns off the microphone.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { WispenActivityActions.endFlowSession?() }
        return .result()
    }
}

struct StopMeetingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop meeting recording"
    static let description = IntentDescription("Stops recording the meeting and writes the recap.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { WispenActivityActions.stopMeeting?() }
        return .result()
    }
}

/// Starts a Wispen flow session WITHOUT opening the app: from Control Center, the Action Button, the
/// Lock Screen or a Shortcuts automation ("When I open Messages → Start Wispen"). iOS lets audio
/// recording intents start the microphone in the background, as long as a Live Activity is shown —
/// Wispen's session Live Activity starts with it.
struct StartFlowSessionIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Wispen"
    static let description = IntentDescription("Gets Wispen listening-ready so the keyboard can dictate without opening the app.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        let start = await MainActor.run { WispenActivityActions.startFlowSession }
        await start?()
        return .result()
    }
}

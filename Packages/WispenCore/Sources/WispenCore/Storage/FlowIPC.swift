import Foundation

/// How the Wispen keyboard and the Wispen app talk on iOS.
///
/// iOS doesn't let keyboard extensions use the microphone. So, like Wispr Flow, the main app runs a
/// background "flow session" that keeps the mic ready, and the keyboard drives it:
///
///   keyboard ──writes FlowRequest──▶ IPC/request.json ──Darwin notification──▶ app records / stops
///   keyboard ◀──Darwin notification── IPC/result.json ◀──writes FlowResult── app transcribes + polishes
///
/// The app also writes `FlowSessionState` (with a heartbeat) so the keyboard knows whether the session
/// is alive or it needs to open the app to start one.
public enum FlowIPC {
    public enum Signal: String, CaseIterable {
        case request = "app.wispen.flow.request"
        case state = "app.wispen.flow.state"
        case result = "app.wispen.flow.result"
        /// The keyboard look changed in the app.
        case theme = "app.wispen.keyboard.theme"
    }

    public static var requestFile: JSONFile<FlowRequest> { JSONFile(name: "request.json", in: WispenPaths.ipc) }
    public static var stateFile: JSONFile<FlowSessionState> { JSONFile(name: "state.json", in: WispenPaths.ipc) }
    public static var resultFile: JSONFile<FlowResult> { JSONFile(name: "result.json", in: WispenPaths.ipc) }
    public static var keyboardStatusFile: JSONFile<KeyboardStatus> { JSONFile(name: "keyboard.json", in: WispenPaths.ipc) }

    /// URL the keyboard opens to start a session: `wispen://flow?request=<id>`.
    public static let urlScheme = "wispen"

    public static func startURL(requestID: String) -> URL {
        URL(string: "\(urlScheme)://flow?request=\(requestID)")!
    }
}

public struct FlowRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case start, stop, cancel }

    public var id: String
    public var action: Action
    public var mode: DictationMode
    public var styleID: String
    /// Command mode: the text selected in the host app.
    public var selectedText: String?
    public var date: Date

    public init(id: String = UUID().uuidString, action: Action, mode: DictationMode = .dictation, styleID: String,
                selectedText: String? = nil, date: Date = Date()) {
        self.id = id
        self.action = action
        self.mode = mode
        self.styleID = styleID
        self.selectedText = selectedText
        self.date = date
    }
}

public struct FlowSessionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No session: the keyboard must open the app.
        case inactive
        /// Session alive, mic ready, not recording.
        case ready
        case recording
        case transcribing
        case polishing
        case error
    }

    public var phase: Phase
    public var mode: DictationMode
    /// ID of the start request currently being served.
    public var requestID: String?
    public var message: String?
    /// Updated every couple of seconds while the session is alive.
    public var heartbeat: Date
    public var sessionEndsAt: Date?
    /// Why the last session ended, when it's over ("Phone locked", "iOS closed Wispen in the background"…).
    public var endReason: String?

    public init(phase: Phase, mode: DictationMode = .dictation, requestID: String? = nil, message: String? = nil,
                heartbeat: Date = Date(), sessionEndsAt: Date? = nil, endReason: String? = nil) {
        self.phase = phase
        self.mode = mode
        self.requestID = requestID
        self.message = message
        self.heartbeat = heartbeat
        self.sessionEndsAt = sessionEndsAt
        self.endReason = endReason
    }

    public static let inactive = FlowSessionState(phase: .inactive)

    /// The app process can be killed without notice, so trust the phase only while the heartbeat is fresh.
    public func isAlive(now: Date = Date(), tolerance: TimeInterval = 6) -> Bool {
        phase != .inactive && now.timeIntervalSince(heartbeat) < tolerance
    }

    /// Not confirmed alive, but the app reported in recently: it may just be slow to wake, so the keyboard
    /// should try it before opening Wispen.
    public func mightBeAlive(now: Date = Date(), within: TimeInterval = 45) -> Bool {
        phase != .inactive && !isAlive(now: now) && now.timeIntervalSince(heartbeat) < within
    }
}

/// Written by the keyboard whenever it opens, so the app can tell it's installed with Full Access.
/// (Without Full Access the keyboard can't write to the shared container at all.)
public struct KeyboardStatus: Codable, Equatable, Sendable {
    public var lastSeen: Date
    public var hasFullAccess: Bool

    public init(lastSeen: Date = Date(), hasFullAccess: Bool) {
        self.lastSeen = lastSeen
        self.hasFullAccess = hasFullAccess
    }
}

public struct FlowResult: Codable, Equatable, Sendable {
    public var requestID: String
    public var mode: DictationMode
    public var text: String
    /// When non-nil, the dictation failed and this explains why.
    public var error: String?
    public var date: Date

    public init(requestID: String, mode: DictationMode, text: String, error: String? = nil, date: Date = Date()) {
        self.requestID = requestID
        self.mode = mode
        self.text = text
        self.error = error
        self.date = date
    }
}

#if canImport(Darwin)
/// Cross-process pings (no payload) between the app and its keyboard extension.
public final class DarwinNotifier: @unchecked Sendable {
    public static let shared = DarwinNotifier()

    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()

    private init() {}

    public func post(_ signal: FlowIPC.Signal) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(signal.rawValue as CFString), nil, nil, true)
    }

    /// Handlers run on the main queue.
    public func observe(_ signal: FlowIPC.Signal, handler: @escaping () -> Void) {
        lock.lock()
        let isFirst = handlers[signal.rawValue] == nil
        handlers[signal.rawValue, default: []].append(handler)
        lock.unlock()
        guard isFirst else { return }

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let notifier = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
            notifier.fire(name.rawValue as String)
        }, signal.rawValue as CFString, nil, .deliverImmediately)
    }

    public func removeAllHandlers() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    private func fire(_ name: String) {
        lock.lock()
        let hs = handlers[name] ?? []
        lock.unlock()
        DispatchQueue.main.async { hs.forEach { $0() } }
    }
}
#endif

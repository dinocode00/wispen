import Foundation

public struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Seconds from the start of the meeting.
    public var start: Double
    public var end: Double
    /// "Me" / "Others" on macOS when system audio is captured; nil otherwise.
    public var speaker: String?
    public var text: String

    public init(id: String = UUID().uuidString, start: Double, end: Double, speaker: String? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var task: String
    public var owner: String?
    public var due: String?
    public var done: Bool

    public init(id: String = UUID().uuidString, task: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.done = done
    }
}

/// The smart recap. Every list is optional in practice: empty sections are simply hidden.
public struct MeetingRecap: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var risks: [String]
    public var followUps: [String]

    public init(title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
                actionItems: [ActionItem] = [], openQuestions: [String] = [], risks: [String] = [],
                followUps: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.followUps = followUps
    }

    public var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty
            && openQuestions.isEmpty && risks.isEmpty && followUps.isEmpty
    }
}

public struct MeetingChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: String
    public var role: Role
    public var text: String
    public var date: Date

    public init(id: String = UUID().uuidString, role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

public struct Meeting: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        /// Transcript is complete but the recap has not been generated (e.g. the app was closed).
        case needsRecap
        case summarizing
        case ready
        case failed
    }

    public var id: String
    public var title: String
    public var startedAt: Date
    public var duration: Double
    public var status: Status
    public var segments: [TranscriptSegment]
    public var recap: MeetingRecap?
    public var chat: [MeetingChatMessage]
    public var errorMessage: String?

    public init(id: String = UUID().uuidString, title: String = "", startedAt: Date = Date(), duration: Double = 0,
                status: Status = .recording, segments: [TranscriptSegment] = [], recap: MeetingRecap? = nil,
                chat: [MeetingChatMessage] = [], errorMessage: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
        self.segments = segments
        self.recap = recap
        self.chat = chat
        self.errorMessage = errorMessage
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let t = recap?.title, !t.isEmpty { return t }
        return "Meeting"
    }

    /// Transcript as text, one line per segment, with speaker labels when known.
    public var transcriptText: String {
        segments.map { seg in
            if let s = seg.speaker { return "\(s): \(seg.text)" }
            return seg.text
        }.joined(separator: "\n")
    }

    public var wordCount: Int { segments.reduce(0) { $0 + $1.text.wordCount } }
}

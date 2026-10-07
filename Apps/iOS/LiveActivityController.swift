import ActivityKit
import Combine
import Foundation
import WispenCore

/// Starts, updates and ends Wispen's Live Activities (Dynamic Island + Lock Screen).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    typealias Attributes = WispenActivityAttributes
    private var flow: Activity<Attributes>?
    private var meeting: Activity<Attributes>?
    private var lastFlowState: Attributes.ContentState?
    private var lastMeetingState: Attributes.ContentState?
    private var bag: Set<AnyCancellable> = []

    private var enabled: Bool {
        AppModel.shared.settings.liveActivities && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Ends activities left over from a previous run (e.g. the app was killed).
    func endStaleActivities() {
        for activity in Activity<Attributes>.activities where activity.id != flow?.id && activity.id != meeting?.id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: Flow session

    func updateFlow(_ session: FlowSessionState, recordingStartedAt: Date?) {
        let phase: Attributes.Phase
        switch session.phase {
        case .inactive:
            endFlow()
            return
        case .ready, .error: phase = .ready
        case .recording: phase = .recording
        case .transcribing: phase = .transcribing
        case .polishing: phase = .polishing
        }
        let state = Attributes.ContentState(
            phase: phase,
            startedAt: phase == .recording ? recordingStartedAt : nil,
            sessionEndsAt: session.sessionEndsAt)
        guard state != lastFlowState else { return } // heartbeats don't need an update
        lastFlowState = state
        flow = upsert(flow, kind: .flowSession, state: state, staleDate: session.sessionEndsAt)
    }

    func endFlow() {
        lastFlowState = nil
        guard let activity = flow else { return }
        flow = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Meetings

    /// Mirrors a meeting recorder into a Live Activity (works while the phone is locked).
    func observe(_ recorder: MeetingRecorder) {
        Publishers.CombineLatest3(recorder.$isRecording, recorder.$recapStage, recorder.$recapProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak recorder] isRecording, stage, progress in
                self?.updateMeeting(isRecording: isRecording, startedAt: recorder?.meeting?.startedAt,
                                    recapStage: stage, progress: progress)
            }
            .store(in: &bag)
    }

    func updateMeeting(isRecording: Bool, startedAt: Date?, recapStage: String?, progress: Double) {
        let state: Attributes.ContentState
        if isRecording {
            state = .init(phase: .meetingRecording, startedAt: startedAt)
        } else if let recapStage {
            // Round progress so we don't send an update for every tiny step.
            state = .init(phase: .meetingSummarizing, progress: (progress * 20).rounded() / 20, detail: recapStage)
        } else {
            endMeeting()
            return
        }
        guard state != lastMeetingState else { return }
        lastMeetingState = state
        meeting = upsert(meeting, kind: .meeting, state: state, staleDate: nil)
    }

    func endMeeting() {
        lastMeetingState = nil
        guard let activity = meeting else { return }
        meeting = nil
        Task { await activity.end(nil, dismissalPolicy: .after(.now + 4)) }
    }

    // MARK: Helpers

    private func upsert(_ activity: Activity<Attributes>?, kind: Attributes.Kind, state: Attributes.ContentState,
                        staleDate: Date?) -> Activity<Attributes>? {
        let content = ActivityContent(state: state, staleDate: staleDate)
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            Task { await activity.update(content) }
            return activity
        }
        guard enabled else { return nil }
        // Live Activities can only be started while Wispen is in the foreground; that's when sessions
        // and meetings start, so this normally succeeds.
        return try? Activity.request(attributes: Attributes(kind: kind), content: content, pushType: nil)
    }
}

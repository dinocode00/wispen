import SwiftUI
import WispenCore

struct MeetingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var recorder: MeetingRecorder
    /// Called before recording starts (iOS ends the keyboard flow session so they don't fight over the mic).
    var willStart: () -> Void = {}
    var extraSources: () -> [MeetingAudioSource] = { [] }
    var micLabel: String? = nil
    @State private var showingRecorder = false

    var body: some View {
        List {
            Section {
                Button {
                    willStart()
                    showingRecorder = true
                    Task { await recorder.start(micLabel: micLabel, extraSources: extraSources()) }
                } label: {
                    Label("Record a meeting", systemImage: "record.circle")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                .disabled(recorder.isRecording)
            } footer: {
                Text("Wispen transcribes on-device as the meeting happens, then writes a recap with decisions, action items and open questions. Audio is never saved.")
            }

            if app.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2",
                                       description: Text("Recaps of your meetings will appear here."))
            }
            ForEach(app.meetings) { meeting in
                NavigationLink { MeetingDetailView(meetingID: meeting.id) } label: { MeetingRow(meeting: meeting) }
                    .swipeActions {
                        Button(role: .destructive) { app.deleteMeeting(meeting) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .navigationTitle("Meetings")
        .sheet(isPresented: $showingRecorder) {
            MeetingRecordingView { showingRecorder = false }
                .interactiveDismissDisabled(recorder.isRecording)
        }
        .onAppear {
            if recorder.isRecording { showingRecorder = true }
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                switch meeting.status {
                case .recording: StatusBadge(text: "Recording", color: .red)
                case .summarizing: StatusBadge(text: "Summarizing", color: .orange)
                case .needsRecap: StatusBadge(text: "No recap", color: .secondary)
                case .failed: StatusBadge(text: "Failed", color: .red)
                case .ready: EmptyView()
                }
            }
            HStack(spacing: 6) {
                Text(meeting.startedAt, style: .date)
                Text("·")
                Text(formatDuration(meeting.duration))
                if let open = meeting.recap?.actionItems.filter({ !$0.done }).count, open > 0 {
                    Text("·")
                    Text("\(open) to-do\(open == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let summary = meeting.recap?.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Live view while a meeting is being recorded.
struct MeetingRecordingView: View {
    @EnvironmentObject var recorder: MeetingRecorder
    var onClose: () -> Void
    @State private var stopping = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text(formatDuration(recorder.elapsed))
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .monospacedDigit()
                    if recorder.isRecording {
                        LevelMeter(level: recorder.level, bars: 9, color: .red)
                            .frame(height: 32)
                    }
                    if let stage = recorder.recapStage {
                        VStack(spacing: 6) {
                            ProgressView(value: recorder.recapProgress)
                            Text(stage).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 40)
                    } else if recorder.backlog > 1 {
                        Text("Catching up on \(recorder.backlog) chunks…").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = recorder.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                    }
                }
                .padding(.vertical, 24)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if (recorder.meeting?.segments ?? []).isEmpty {
                                Text("The live transcript appears here, about 30 seconds behind.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 30)
                            }
                            ForEach(recorder.meeting?.segments ?? []) { seg in
                                SegmentRow(segment: seg).id(seg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: recorder.meeting?.segments.count) {
                        if let last = recorder.meeting?.segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }

                Button {
                    stopping = true
                    Task {
                        await recorder.stop()
                        stopping = false
                        onClose()
                    }
                } label: {
                    Label(stopping ? "Writing recap…" : "Stop & summarize", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!recorder.isRecording || stopping)
                .padding()
            }
            .navigationTitle(recorder.isRecording ? "Recording" : "Meeting")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !recorder.isRecording && !stopping { Button("Close") { onClose() } }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let speaker = segment.speaker {
                    Text(speaker).font(.caption.weight(.semibold))
                        .foregroundStyle(speaker == "Me" ? Color.wispenAccent : Color.orange)
                }
                Text(formatDuration(segment.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(segment.text).textSelection(.enabled)
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var recorder: MeetingRecorder
    let meetingID: String
    @State private var tab = 0
    @State private var renaming = false
    @State private var newTitle = ""

    private var meeting: Meeting? { app.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let meeting {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Recap").tag(0)
                    Text("Transcript").tag(1)
                    Text("Ask").tag(2)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)

                switch tab {
                case 0: RecapView(meeting: meeting)
                case 1: TranscriptView(meeting: meeting)
                default: MeetingChatView(meetingID: meeting.id)
                }
            }
            .navigationTitle(meeting.displayTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: shareText(meeting)) { Label("Share recap", systemImage: "square.and.arrow.up") }
                        Button { Pasteboard.copy(shareText(meeting)) } label: { Label("Copy recap", systemImage: "doc.on.doc") }
                        Button { Pasteboard.copy(meeting.transcriptText) } label: { Label("Copy transcript", systemImage: "text.quote") }
                        Button { newTitle = meeting.displayTitle; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button {
                            Task { await recorder.summarize(meetingID: meeting.id) }
                        } label: { Label(meeting.recap == nil ? "Generate recap" : "Regenerate recap", systemImage: "sparkles") }
                            .disabled(meeting.status == .summarizing)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Rename meeting", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Save") {
                    var m = meeting
                    m.title = newTitle
                    app.save(m)
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Meeting not found", systemImage: "questionmark")
        }
    }

    private func shareText(_ m: Meeting) -> String {
        (m.recap ?? MeetingRecap(title: m.displayTitle)).markdown(date: m.startedAt, duration: m.duration)
    }
}

struct RecapView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var recorder: MeetingRecorder
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 6) {
                    Text(meeting.startedAt, style: .date)
                    Text(meeting.startedAt, style: .time)
                    Text("·")
                    Text(formatDuration(meeting.duration))
                    Text("·")
                    Text("\(meeting.wordCount) words")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if meeting.status == .summarizing {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: recorder.recapProgress)
                        Text(recorder.recapStage ?? "Summarizing…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = meeting.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if meeting.recap == nil, meeting.status != .summarizing, !meeting.segments.isEmpty {
                    Button {
                        Task { await recorder.summarize(meetingID: meeting.id) }
                    } label: { Label("Generate recap", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent)
                }

                if let recap = meeting.recap {
                    if !recap.summary.isEmpty {
                        Text(recap.summary).font(.body)
                    }
                    if !recap.actionItems.isEmpty {
                        RecapSection(title: "Action items", icon: "checklist", color: .green) {
                            ForEach(recap.actionItems) { item in ActionItemRow(meeting: meeting, item: item) }
                        }
                    }
                    bulletSection("Decisions", icon: "checkmark.seal", color: .blue, items: recap.decisions)
                    bulletSection("Key points", icon: "list.bullet", color: .wispenAccent, items: recap.keyPoints)
                    bulletSection("Open questions", icon: "questionmark.bubble", color: .orange, items: recap.openQuestions)
                    bulletSection("Risks & concerns", icon: "exclamationmark.triangle", color: .red, items: recap.risks)
                    bulletSection("Follow-ups", icon: "arrow.uturn.forward", color: .teal, items: recap.followUps)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bulletSection(_ title: String, icon: String, color: Color, items: [String]) -> some View {
        if !items.isEmpty {
            RecapSection(title: title, icon: icon, color: color) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(color)
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct RecapSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
            content
        }
    }
}

struct ActionItemRow: View {
    @EnvironmentObject var app: AppModel
    let meeting: Meeting
    let item: ActionItem

    var body: some View {
        Button {
            var m = meeting
            if let i = m.recap?.actionItems.firstIndex(where: { $0.id == item.id }) {
                m.recap?.actionItems[i].done.toggle()
                app.save(m)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                    let meta = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    @State private var search = ""

    var body: some View {
        List {
            ForEach(meeting.segments.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { seg in
                SegmentRow(segment: seg)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search transcript")
    }
}

/// Ask questions about a meeting ("What did we decide about pricing?").
struct MeetingChatView: View {
    @EnvironmentObject var app: AppModel
    let meetingID: String
    @State private var question = ""
    @State private var thinking = false

    private var meeting: Meeting? { app.meetings.first { $0.id == meetingID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if (meeting?.chat ?? []).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask anything about this meeting.").foregroundStyle(.secondary)
                            ForEach(["What did we decide?", "What do I need to do next?", "What were the concerns about the timeline?"], id: \.self) { s in
                                Button(s) { question = s; ask() }.buttonStyle(.bordered)
                            }
                        }
                    }
                    ForEach(meeting?.chat ?? []) { msg in
                        HStack {
                            if msg.role == .user { Spacer(minLength: 40) }
                            Text(msg.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(msg.role == .user ? Color.wispenAccent.opacity(0.18) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 14))
                            if msg.role == .assistant { Spacer(minLength: 40) }
                        }
                    }
                    if thinking { ProgressView().padding(.leading, 8) }
                }
                .padding()
            }
            Divider()
            HStack {
                TextField("Ask about this meeting…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            }
            .padding()
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, var m = meeting else { return }
        question = ""
        m.chat.append(MeetingChatMessage(role: .user, text: q))
        app.save(m)
        thinking = true
        let snapshot = m
        Task {
            var reply: String
            if let generator = app.generator, await generator.isAvailable {
                do { reply = try await MeetingQA(generator: generator).answer(question: q, meeting: snapshot) } catch { reply = "Sorry — \(error.localizedDescription)" }
            } else {
                reply = "Asking questions needs Apple Intelligence (or Ollama on Mac)."
            }
            var updated = app.meetings.first { $0.id == meetingID } ?? snapshot
            updated.chat.append(MeetingChatMessage(role: .assistant, text: reply))
            app.save(updated)
            thinking = false
        }
    }
}

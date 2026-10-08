import SwiftUI
import WispenCore

/// "Who's who?": listen to a few lines from each detected voice and name them. Giving two voices
/// the same name merges them; the recap is written afterwards with the real names.
struct SpeakerReviewView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var recorder: MeetingRecorder
    @StateObject private var player = SnippetPlayer()
    @Environment(\.dismiss) private var dismiss

    let meetingID: String
    @State private var names: [String: String] = [:]
    @State private var peopleCount = 0 // 0 = automatic
    @State private var working = false

    private var meeting: Meeting? { app.meetings.first { $0.id == meetingID } }
    private var hasAudio: Bool { SpeakerReviewStore.hasAudio(meetingID) }

    var body: some View {
        NavigationStack {
            Group {
                if let meeting {
                    content(meeting)
                } else {
                    ContentUnavailableView("Meeting not found", systemImage: "questionmark")
                }
            }
            .navigationTitle("Who's who?")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { player.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(working)
                }
            }
            .onAppear {
                peopleCount = meeting?.expectedSpeakers ?? 0
            }
            .onDisappear { player.stop() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        let speakers = meeting.speakers.filter { $0 != "Me" }
        let suggestions = SpeakerReview.mentionedNames(in: meeting.segments)
        List {
            Section {
                Text("Wispen heard \(speakers.count) voice\(speakers.count == 1 ? "" : "s"). Listen to a few lines from each and type who it is. If two voices are the same person, give them the same name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if hasAudio {
                    HStack {
                        Picker("People in the meeting", selection: $peopleCount) {
                            Text("Auto").tag(0)
                            ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Button("Re-detect") {
                            working = true
                            Task {
                                await recorder.redetectSpeakers(meetingID: meetingID, count: peopleCount == 0 ? nil : peopleCount)
                                names = [:]
                                working = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(working)
                    }
                    if working {
                        ProgressView(value: recorder.recapProgress) { Text("Listening for voices…").font(.caption) }
                    }
                }
            }

            ForEach(speakers, id: \.self) { speaker in
                Section {
                    TextField("Name (e.g. Sam)", text: binding(for: speaker))
                        .sentenceCapitalization()
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(["Me"] + suggestions, id: \.self) { name in
                                    Button(name) { names[speaker] = name }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    ForEach(SpeakerReview.samples(in: meeting.segments, for: speaker)) { line in
                        HStack(alignment: .top, spacing: 10) {
                            if hasAudio {
                                Button {
                                    player.toggle(line, meetingID: meetingID)
                                } label: {
                                    Image(systemName: player.playingID == line.id ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(SegmentRow.color(for: speaker))
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatDuration(line.start)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                Text("“\(line.text)”").font(.callout).lineLimit(4)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Circle().fill(SegmentRow.color(for: speaker)).frame(width: 8, height: 8)
                        Text(speaker)
                        Spacer()
                        Text("\(meeting.segments.filter { $0.speaker == speaker }.count) lines")
                    }
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Label("Save & write recap", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
                Button("Skip — keep Speaker 1, 2…") {
                    names = [:]
                    save()
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text(hasAudio
                     ? "The meeting audio is kept only for this step and deleted when you save or skip (or after 24 hours)."
                     : "You can still fix individual lines later: long-press a line in the transcript.")
            }
        }
    }

    private func binding(for speaker: String) -> Binding<String> {
        Binding(get: { names[speaker] ?? "" }, set: { names[speaker] = $0 })
    }

    private func save() {
        player.stop()
        let chosen = names
        working = true
        dismiss()
        Task { await recorder.finishSpeakerReview(meetingID: meetingID, names: chosen) }
    }
}

/// Lets `.sheet(item:)` present a meeting by id.
struct MeetingRef: Identifiable, Hashable {
    let id: String
}

import SwiftUI
import WispenCore

/// Settings shared by iOS and macOS.
struct SharedSettingsSections: View {
    @EnvironmentObject var app: AppModel
    @State private var aiStatus = GeneratorFactory.appleIntelligenceStatus()

    private let languages: [(String?, String)] = [
        (nil, "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"),
        ("ko", "Korean"), ("hi", "Hindi"), ("ru", "Russian"),
    ]

    var body: some View {
        Section {
            Picker("Model", selection: $app.settings.whisperModelID) {
                ForEach(WhisperModelOption.all) { option in
                    Text("\(option.name) — \(option.detail)").tag(option.id)
                }
            }
            if !app.settings.whisperModel.englishOnly {
                Picker("Language", selection: $app.settings.language) {
                    ForEach(languages, id: \.1) { language in Text(language.1).tag(language.0) }
                }
            }
            HStack {
                Text("Status")
                Spacer()
                Text(app.speechModel.label).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if !app.speechModel.isReady {
                Button("Download & prepare model") { Task { await app.prepareSpeechModel() } }
            }
        } header: {
            Text("Speech recognition")
        } footer: {
            Text("Runs entirely on-device with Whisper. The first download needs Wi-Fi; after that it works offline.")
        }
        .onChange(of: app.settings.whisperModelID) {
            Task { await app.prepareSpeechModel() }
        }

        Section {
            Picker("AI model", selection: $app.settings.llmProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if app.settings.llmProvider == .appleIntelligence {
                Label(aiStatus.message, systemImage: aiStatus.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(aiStatus.ready ? Color.green : Color.orange)
                    .font(.callout)
            }
            if app.settings.llmProvider == .ollama {
                TextField("Server URL", text: $app.settings.ollamaURL).noAutocapitalization()
                TextField("Model (e.g. llama3.2, qwen2.5:7b)", text: $app.settings.ollamaModel).noAutocapitalization()
                Stepper("Context: \(app.settings.ollamaContextTokens) tokens", value: $app.settings.ollamaContextTokens,
                        in: 2048...131072, step: 2048)
            }
            Picker("Default style", selection: $app.settings.defaultStyleID) {
                ForEach(app.allStyles) { Text("\($0.emoji) \($0.name)").tag($0.id) }
            }
        } header: {
            Text("AI editing")
        } footer: {
            Text("Apple Intelligence is free and private. Ollama is a free app that runs larger open models on your Mac (ollama.com).")
        }

        Section {
            Toggle("AI cleanup", isOn: $app.settings.aiCleanup)
            Toggle("Remove filler words", isOn: $app.settings.removeFillers)
            Toggle("Follow self-corrections", isOn: $app.settings.resolveSelfCorrections)
            Toggle("Format spoken lists", isOn: $app.settings.autoFormatLists)
            Toggle("Spoken punctuation (“comma”, “period”)", isOn: $app.settings.spokenPunctuation)
        } header: {
            Text("Cleanup")
        } footer: {
            Text("“New line” and “new paragraph” always work. Self-corrections: “at 5, no wait, 6” becomes “at 6”.")
        }

        Section {
            Toggle("Keep history", isOn: $app.settings.keepHistory)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Everything — audio, transcripts and AI — stays on your devices. Meeting audio is deleted as soon as it's transcribed.")
        }
    }
}

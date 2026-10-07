import SwiftUI
import UniformTypeIdentifiers
import WispenCore

/// Dictionary, snippets and styles.
struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @State private var importing = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                NavigationLink { DictionaryView() } label: {
                    Label { Text("Dictionary").badge(app.dictionary.count) } icon: { Image(systemName: "character.book.closed") }
                }
                NavigationLink { SnippetsView() } label: {
                    Label { Text("Snippets").badge(app.snippets.count) } icon: { Image(systemName: "text.badge.plus") }
                }
                NavigationLink { StylesView() } label: {
                    Label { Text("Styles").badge(app.allStyles.count) } icon: { Image(systemName: "paintpalette") }
                }
            } footer: {
                Text("Dictionary words are spelled right every time. Snippets expand when you say their trigger. Styles change the tone of your writing.")
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share library file", systemImage: "square.and.arrow.up") }
                } else {
                    Button { exportURL = try? app.exportLibraryFile() } label: {
                        Label("Export library", systemImage: "square.and.arrow.up")
                    }
                }
                Button { importing = true } label: { Label("Import library", systemImage: "square.and.arrow.down") }
            } header: {
                Text("Sync")
            } footer: {
                Text("Move your dictionary, snippets and styles between iPhone and Mac with AirDrop or Files.")
            }
        }
        .navigationTitle("Library")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                do { try app.importLibrary(from: url) } catch { app.lastError = "Import failed: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: Dictionary

struct DictionaryView: View {
    @EnvironmentObject var app: AppModel
    @State private var editing: DictionaryEntry?
    @State private var search = ""

    private var filtered: [DictionaryEntry] {
        let sorted = app.dictionary.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.term.localizedCaseInsensitiveContains(search) || $0.soundsLike.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        List {
            if app.dictionary.isEmpty {
                ContentUnavailableView("No words yet", systemImage: "character.book.closed",
                                       description: Text("Add names, jargon and brands so Wispen always spells them right."))
            }
            ForEach(filtered) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.term).font(.body.weight(.medium)).foregroundStyle(.primary)
                        if !entry.soundsLike.isEmpty {
                            Text("Heard as: " + entry.soundsLike.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { app.dictionary.removeAll { $0.id == entry.id } } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = DictionaryEntry(term: "") } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { saved in
                app.dictionary.removeAll { $0.id == saved.id }
                if !saved.term.isEmpty { app.dictionary.append(saved) }
            }
        }
    }
}

struct DictionaryEditor: View {
    @State var entry: DictionaryEntry
    var onSave: (DictionaryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var soundsLikeText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Word or name (e.g. Siobhan)", text: $entry.term).noAutocapitalization()
                } footer: {
                    Text("Exact spelling and capitalization Wispen should use.")
                }
                Section {
                    TextField("e.g. shiv on, chevonne", text: $soundsLikeText, axis: .vertical).noAutocapitalization()
                } header: {
                    Text("Sometimes heard as (optional)")
                } footer: {
                    Text("Comma-separated. Wispen replaces these with the word above.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(entry.term.isEmpty ? "New word" : entry.term)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.soundsLike = soundsLikeText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(entry.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { soundsLikeText = entry.soundsLike.joined(separator: ", ") }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

// MARK: Snippets

struct SnippetsView: View {
    @EnvironmentObject var app: AppModel
    @State private var editing: Snippet?

    var body: some View {
        List {
            if app.snippets.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                                       description: Text("Say “my email” and get your email address. Say “my calendar link” and get the link."))
            }
            ForEach(app.snippets) { snippet in
                Button { editing = snippet } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(snippet.trigger)”").font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(snippet.expansion).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { app.snippets.removeAll { $0.id == snippet.id } } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Snippet(trigger: "", expansion: "") } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { saved in
                app.snippets.removeAll { $0.id == saved.id }
                app.snippets.append(saved)
            }
        }
    }
}

struct SnippetEditor: View {
    @State var snippet: Snippet
    var onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. my email", text: $snippet.trigger).noAutocapitalization()
                } header: { Text("When I say") }
                Section {
                    TextField("e.g. rex@example.com", text: $snippet.expansion, axis: .vertical)
                        .lineLimit(3...10).noAutocapitalization()
                } header: { Text("Type this") }
            }
            .formStyle(.grouped)
            .navigationTitle("Snippet")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(snippet); dismiss() }
                        .disabled(snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty || snippet.expansion.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

// MARK: Styles

struct StylesView: View {
    @EnvironmentObject var app: AppModel
    @State private var editing: DictationStyle?

    var body: some View {
        List {
            Section {
                ForEach(app.allStyles) { style in
                    HStack {
                        Text(style.emoji)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.name).font(.body.weight(.medium))
                            Text(style.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if app.settings.defaultStyleID == style.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.wispenAccent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.settings.defaultStyleID = style.id }
                    .swipeActions {
                        if !style.isBuiltIn {
                            Button(role: .destructive) { app.customStyles.removeAll { $0.id == style.id } } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = style } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
                }
            } footer: {
                Text("Tap to make a style the default. On iPhone, switch styles from the Wispen keyboard. On Mac, styles also follow the app you're typing in.")
            }
        }
        .navigationTitle("Styles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = DictationStyle(name: "", emoji: "🪄", instructions: "")
                } label: { Label("New style", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { style in
            StyleEditor(style: style) { saved in
                app.customStyles.removeAll { $0.id == saved.id }
                app.customStyles.append(saved)
            }
        }
    }
}

struct StyleEditor: View {
    @State var style: DictationStyle
    var onSave: (DictationStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("🪄", text: $style.emoji).frame(width: 44)
                        TextField("Name (e.g. Pirate, LinkedIn)", text: $style.name)
                    }
                }
                Section {
                    TextField("e.g. Upbeat and concise, with one emoji at the end.", text: $style.instructions, axis: .vertical)
                        .lineLimit(3...8)
                } header: { Text("How should it sound?") }
                Section {
                    Toggle("Lowercase sentence starts", isOn: $style.lowercaseSentenceStarts)
                    Toggle("No period at the end", isOn: $style.dropTrailingPeriod)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Style")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(style); dismiss() }
                        .disabled(style.name.isEmpty || style.instructions.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }
}

// MARK: History

struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var search = ""
    @State private var showRaw: Set<String> = []

    private var filtered: [HistoryItem] {
        guard !search.isEmpty else { return app.history }
        return app.history.filter { $0.output.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if !app.history.isEmpty {
                Section {
                    HStack {
                        stat("\(app.history.count)", "dictations")
                        Spacer()
                        stat("\(app.totalWordsDictated)", "words")
                        Spacer()
                        stat("\(Int(app.totalWordsDictated / 40))m", "typing saved")
                    }
                }
            } else {
                ContentUnavailableView("Nothing yet", systemImage: "clock",
                                       description: Text("Your dictations appear here so you can copy them again."))
            }
            ForEach(filtered) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(app.style(id: item.styleID).emoji)
                        if item.mode == .command { StatusBadge(text: "Command", color: .orange) }
                        if let appName = item.appName { Text(appName).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(showRaw.contains(item.id) ? item.raw : item.output)
                        .textSelection(.enabled)
                        .foregroundStyle(showRaw.contains(item.id) ? .secondary : .primary)
                    HStack(spacing: 16) {
                        Button { Pasteboard.copy(item.output) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button {
                            if showRaw.contains(item.id) { showRaw.remove(item.id) } else { showRaw.insert(item.id) }
                        } label: {
                            Label(showRaw.contains(item.id) ? "Show polished" : "Show original", systemImage: "eye")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                let ids = offsets.map { filtered[$0].id }
                app.deleteHistory(at: IndexSet(app.history.indices.filter { ids.contains(app.history[$0].id) }))
            }
        }
        .searchable(text: $search)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Clear history", role: .destructive) { app.clearHistory() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

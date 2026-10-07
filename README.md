# Wispen

Your own private Wispr Flow. Talk instead of type, anywhere — on your **iPhone** (via the Wispen keyboard)
and your **Mac** (hold `fn`). Wispen also records meetings and writes a smart recap.

Everything runs **on your devices** and costs nothing:

| | How | Cost |
|---|---|---|
| Speech → text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI Whisper on the Apple Neural Engine) | Free, offline |
| AI editing, recaps | Apple Intelligence on-device model (iOS 26 / macOS 26) | Free, offline |
| Optional bigger model (Mac) | [Ollama](https://ollama.com) running locally | Free, offline |
| Fallback | Built-in rule-based cleanup | Free, offline |

## Features

**Dictation (iPhone keyboard + Mac `fn` key)**
- **Smart cleanup**: removes *um/uh/like*, stutters and false starts, fixes punctuation and grammar, keeps your voice.
- **Self-corrections**: “let's meet at 5, no wait, 6” → “Let's meet at 6.” · “…scratch that” deletes the sentence.
- **Lists**: “first … second … third …” becomes a numbered list. “New line”, “new paragraph”, “bullet point” work.
- **Styles**: Polished, Formal, Casual, Texting, Notes, Verbatim + your own (“LinkedIn”, “Pirate”…).
  On Mac, the style follows the app you're in (Messages → Texting, Mail → Formal, Slack → Casual; customizable).
- **Dictionary**: names and jargon spelled right every time (“Siobhan”, “Kubernetes”), including what it
  *mis-hears* (“why spin” → “Wispen”). Also biases Whisper toward those words.
- **Snippets**: say “my email” → `you@example.com`; “my calendar link” → the link. Expanded byte-for-byte.
- **Command mode**: select text and say “make this more concise” / “translate to Spanish” / “turn into bullet
  points”. With nothing selected, say “write a polite no to this invite” and it writes it.
- **Smart insertion**: adds the space and lowercases the first word when you dictate mid-sentence.
- **History** with original vs. polished text and stats.

**Wispen keyboard (iPhone)**
- Full **QWERTY** keyboard with 123 / #+= layers, shift + caps lock (double-tap), auto-capitalization,
  double-space “.”, key pop-ups, repeating delete (holds into whole words), and **drag the space bar to move the cursor**.
- **Suggestions + conservative autocorrect** (your Wispen dictionary words come first and are never “corrected”;
  backspace right after an autocorrection undoes it).
- Toolbar: style picker, **✨ command mode**, **🎤 dictation**. While Wispen listens, a voice panel replaces the keys.

**Dynamic Island & Lock Screen**
- Live Activity shows the flow session (ready / listening with a timer / writing, and when it will end) with an
  **End** button, and meetings (live timer → recap progress) with a **Stop & summarize** button.

**Meetings (iPhone and Mac)**
- Records 30–60+ minute meetings, transcribing on-device **while** you record (live transcript).
- **Audio is never saved** — each ~30 s chunk is deleted the moment it's transcribed.
- **Smart recap**: summary, key points, decisions, **action items** (owner + due date, tappable checkboxes),
  open questions, risks, and follow-ups — each section only appears when the meeting warrants it.
- **Ask the meeting**: “What did Sam say about the budget?” — answered from the transcript.
- **Mac**: also captures system audio (Zoom/Meet/Teams), labelling the transcript **Me** vs **Others**.
- Share/copy the recap as Markdown.

## How it works on iPhone

iOS doesn't let keyboards use the microphone, so Wispen does what Wispr Flow does:

1. In any app, switch to the **Wispen keyboard** and tap the mic.
2. The first time, it opens the Wispen app, which starts a **flow session** (iOS shows an orange mic dot) and
   starts listening. **Swipe back** to your app and keep talking.
3. Tap the mic again → Wispen transcribes and polishes, and the keyboard types the result.
4. From then on the keyboard works **without** leaving your app, until the session ends after
   *N* idle minutes (default 15; change it on the Flow tab). Wispen only records while you're dictating.

## Setup

You need a Mac with **Xcode 26** (free from the App Store) and your iPhone. A free Apple ID works.

### 1. Generate the Xcode project

```bash
brew install xcodegen          # one-time (https://brew.sh if you don't have Homebrew)
git clone <this repo> && cd wispen
```

Open `Config/Wispen.xcconfig` and set **`WISPEN_BUNDLE_PREFIX`** to something unique to you
(e.g. `com.rexsmith`). Optionally set `WISPEN_TEAM_ID`. Then:

```bash
xcodegen
open Wispen.xcodeproj
```

Re-run `xcodegen` whenever you pull changes that add files.

### 2. Sign in and pick your team

Xcode › Settings › Accounts → add your Apple ID. Then for **each target** (Wispen, WispenKeyboard, WispenWidgets, WispenMac)
→ *Signing & Capabilities* → Team → your *(Personal Team)*. (Skip this if you set `WISPEN_TEAM_ID`.)

### 3. Install on iPhone

1. Plug in your iPhone, enable **Developer Mode** (Settings › Privacy & Security › Developer Mode).
2. Select the **Wispen** scheme and your iPhone, press **Run** (⌘R). (This also installs the keyboard and the
   Dynamic Island widget — 3 App IDs, well within a free account's limit.)
3. On the iPhone: Settings › General › VPN & Device Management → trust your developer certificate.
4. Open Wispen → it downloads the speech model (~630 MB, use Wi-Fi). The first load takes a couple of minutes
   while iOS optimizes it for the Neural Engine; after that it's fast.
5. Add the keyboard: Settings › General › Keyboard › Keyboards › **Add New Keyboard… › Wispen**, then tap
   **Wispen** and turn on **Allow Full Access**. (Required so the keyboard can talk to the app. Nothing leaves
   your phone — there's no network code in the keyboard.)
6. Make sure **Apple Intelligence** is on (Settings › Apple Intelligence & Siri).

> **Free Apple ID note:** apps you install this way expire after **7 days**. Just press Run in Xcode again
> (your data is kept). [SideStore](https://sidestore.io) can refresh it automatically. A paid developer
> account ($99/yr) makes it last a year.

### 4. Install on Mac

1. Select the **WispenMac** scheme → *My Mac* → **Run**. A waveform icon appears in the menu bar.
2. Allow **Microphone**, and **Accessibility** (System Settings › Privacy & Security › Accessibility → Wispen)
   so it can type for you.
3. If `fn` opens the emoji picker: System Settings › Keyboard › *Press 🌐 key to* → **Do Nothing**.
4. To keep it, drag `Wispen.app` from Xcode's Products folder (Product › Show Build Folder) into `/Applications`,
   and add it to System Settings › General › Login Items.

| Mac shortcut | Does |
|---|---|
| Hold `fn` | Talk; release to type |
| Double-tap `fn` | Hands-free; tap `fn` to finish |
| Hold `fn` + `control` | Command mode on the selected text |

**Optional — Ollama for even better recaps on Mac:** install [Ollama](https://ollama.com), run
`ollama pull qwen2.5:7b` (or `llama3.2`), then Wispen › Settings › AI model → *Ollama*, model `qwen2.5:7b`.

### Sync your dictionary between iPhone and Mac

Library › Export library → AirDrop the file → Import library on the other device. (iCloud sync needs a paid
developer account.)

## Project layout

```
Packages/WispenCore/   Platform-independent logic + 57 unit tests (runs on Linux/macOS: `swift test`)
  Text/                Filler removal, self-corrections, lists, dictionary, snippets, styles, insertion,
                       keyboard typing rules (auto-caps, autocorrect, suggestions)
  AI/                  Prompts, cleanup pipeline + guardrails, command mode, Ollama client
  Meetings/            Map-reduce recap for long meetings, recap parser, Q&A retrieval
  Storage/             JSON storage, keyboard ⇄ app IPC
Apps/Shared/           iOS + macOS: audio capture, WhisperKit, Apple Intelligence, engines, shared SwiftUI
Apps/iOS/              iPhone app (flow session, home, settings)
Apps/Keyboard/         Wispen keyboard extension (QWERTY + voice)
Apps/LiveActivity/     Live Activity model + Lock Screen button intents (shared by app and widget)
Apps/Widgets/          Dynamic Island / Lock Screen UI (widget extension)
Apps/macOS/            Menu-bar app (fn hotkey, overlay, paste, system-audio capture)
project.yml            XcodeGen project spec
```

### Design notes

- **Long meetings vs. a small model**: Apple's on-device model has a ~4k-token context; an hour of talk is
  ~12k tokens. Wispen extracts structured notes from each chunk, merges them hierarchically, then writes
  the final recap. If a merge fails, notes are merged mechanically so you always get a recap.
- **Never lose a dictation**: model output is validated (no answering your question instead of transcribing
  it, no truncation, snippets intact). Anything suspicious falls back to the rule-based result.
- **Background-safe**: the keyboard flow runs while Wispen is in the background, where iOS forbids GPU use,
  so Whisper runs on the Neural Engine/CPU only.

### Development

```bash
cd Packages/WispenCore && swift test
```

## Troubleshooting

- **Keyboard says “Turn on Allow Full Access”** → Settings › General › Keyboard › Keyboards › Wispen.
- **Keyboard opens the app every time** → the session ended (idle timeout) or iOS closed Wispen. Raise the
  timeout on the Flow tab.
- **“Apple Intelligence unavailable”** → turn it on in Settings, and wait for its model to download. Until then
  Wispen uses rule-based cleanup, and meeting recaps wait (“Generate recap” later).
- **Mac doesn't type** → re-check Accessibility. After rebuilding, macOS may need you to toggle Wispen off/on there.
- **No Dynamic Island / Lock Screen activity** → Settings › Wispen › Live Activities must be on, and the toggle in
  Wispen › Settings.
- **App Group errors when building** → `WISPEN_BUNDLE_PREFIX` must be unique; change it and re-run `xcodegen`.

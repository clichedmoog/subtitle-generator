# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run all tests (requires Xcode, not just CLI tools)
```

### Running as .app bundle (with Dock icon, file associations)

```bash
swift build
cp .build/debug/SubtitleGenerator build/SubtitleGenerator.app/Contents/MacOS/
open build/SubtitleGenerator.app
```

After modifying `Info.plist`, re-register with Launch Services:
```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/SubtitleGenerator.app
```

### Testing requires Xcode

`swift test` needs Xcode (not just Command Line Tools) because XCTest is bundled with Xcode:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Architecture

This is a macOS SwiftUI app (Swift Package Manager, macOS 14+) that generates subtitles from video/audio using mlx-whisper and optionally translates them via Claude/OpenAI APIs.

### Core Flow

1. **User adds files** (drag & drop, file picker, or Finder "Open With")
2. **Language detection** — mlx-whisper on multiple 30-second clips until a common language is found (up to 8 attempts)
3. **Transcription** — mlx-whisper generates JSON with segments
4. **Post-processing** — Filter repetitive patterns, merge consecutive duplicates, apply subtitle delay
5. **SRT generation** — JSON segments → SRT format with language postfix (e.g., `file.ja.srt`)
6. **Embedding** — ffmpeg embeds subtitle track into video with ISO 639-2 language code
7. **Translation** (optional) — Claude CLI / Claude API / OpenAI API translates SRT in parallel

### Key Components

- **TranscriptionEngine** (`ObservableObject`) — Orchestrates the entire pipeline. Runs on background `DispatchQueue`. Uses `Process` to call external binaries (mlx_whisper, ffmpeg, ffprobe, claude). Thread-safe process cancellation via `NSLock`-protected `currentProcess`.

- **TranslationEngine** — Three backends: `claude -p` (CLI, uses subscription auth), Claude API (direct HTTP), OpenAI API (direct HTTP). All translations run in parallel via `DispatchGroup`.

- **ContentView** — Single-window SwiftUI view. Options persisted via `@AppStorage`. File list persisted via `UserDefaults`. Receives files from AppDelegate via `NotificationCenter`.

- **Models.swift** — All enums (`WhisperModel`, `Language`, `Sensitivity`, `SubtitleDelay`, `OutputMode`, `AuthMethod`, `TranslationModel`, `TranslationLanguage`, `FileStatus`, `FileItem`).

### External Dependencies (CLI tools, not bundled)

- `mlx_whisper` — Speech-to-text (Apple Silicon GPU via MLX)
- `ffmpeg` / `ffprobe` — Video processing, subtitle embedding, duration queries
- `claude` — Translation via Claude Code subscription (optional)

Binary lookup searches: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`

### Important Patterns

- **Language codes**: Whisper outputs ISO 639-1 (2-char: `ja`), MP4 containers require ISO 639-2 (3-char: `jpn`). `langCode3()` maps between them. Using 2-char codes for MP4 subtitle metadata silently fails.

- **Filename handling**: mlx-whisper truncates filenames with multiple dots (e.g., `file.H.265.24.00.mp4` → `file.H.265.24.json`). JSON files are found by scanning tmpDir for `*.json` instead of constructing expected paths.

- **Process output buffering**: Python buffers stdout when piped. `PYTHONUNBUFFERED=1` environment variable is required for real-time progress updates.

- **Repetitive text filtering**: `isRepetitive()` catches single-char repeats, few-unique-char long text (≤4 chars, ≥12 length), pattern repeats (1-10 chars), and comma-separated repeats (70%+ majority). Brackets `「」` are stripped before checking.

- **6-layer post-processing**: min duration (0.3s), repetitive patterns, punctuation-only, hallucination blacklist, over-dense text (>25 chars/sec), end-of-video hallucination (last 30s + high no_speech_prob).

- **NaN in JSON**: mlx-whisper sometimes produces NaN/Infinity in `no_speech_prob` or `compression_ratio`. JSONSerialization rejects these — sanitize before parsing.

- **Whisper compression-ratio-threshold**: Only triggers retry, does NOT delete segments. Post-processing is the only reliable filter for repetitive hallucinations.

- **Dynamic queue**: `process()` takes a `getFiles` closure instead of a file array, re-checking for new pending files after each completion. Files added during processing are automatically picked up.

- **Translation retry**: Up to 3 attempts with SRT validation. Checks for timestamp patterns and AI refusal patterns.

- **Parallel transcription + translation**: Translation runs on `.utility` queue while next file transcribes on `.userInitiated`. GPU (whisper) and network (API) don't compete.

- **Debug logging**: Gated with `#if DEBUG`. Writes to `~/Desktop/SubtitleGenerator_debug.log`.

- **UI disabled state**: Use `.opacity(0.3)` instead of gray for disabled buttons. Preserves color identity.

## Distribution

```bash
# Build DMG
./scripts/build-dmg.sh
```

TODO: ffmpeg embedding in app bundle, code signing, notarization. See memory/distribution_plan.md.

## Commit Convention

Format: `type(scope): subject` (lowercase subject)
Types: feat, fix, ci, docs, refactor, style, perf, chore

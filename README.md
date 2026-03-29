# SubtitleGenerator

AI-powered subtitle generator for macOS. Transcribe video/audio files and translate subtitles using Apple Silicon GPU acceleration.

## Features

- **AI Transcription** — mlx-whisper (Whisper large-v3-turbo) on Apple Silicon GPU
- **Auto Language Detection** — Progressive 4-stage sampling across video
- **Multi-language Translation** — Claude / OpenAI API with parallel processing
- **Batch Processing** — Drag & drop multiple files, dynamic queue
- **Smart Post-processing** — 6-layer filter removes hallucinations, repetitions, noise
- **Video Embedding** — Embed subtitles directly into MP4/MOV with language metadata
- **Progress Tracking** — Per-file progress bars, overall ETA, Dock icon progress

## Requirements

- macOS 14.0+
- Apple Silicon Mac (M1/M2/M3/M4/M5)

### Dependencies

```bash
brew install ffmpeg
pipx install mlx-whisper
```

Optional (for translation):
- [Claude Code](https://claude.ai/code) subscription, or
- Anthropic API key (`console.anthropic.com`), or
- OpenAI API key (`platform.openai.com`)

## Build & Run

```bash
# Build
swift build

# Run as .app bundle (with Dock icon)
swift build
cp .build/debug/SubtitleGenerator build/SubtitleGenerator.app/Contents/MacOS/
open build/SubtitleGenerator.app
```

## Usage

1. **Add files** — Drag & drop video/audio files, or click "추가"
2. **Configure** — Select model, language, sensitivity, output mode
3. **Start** — Click "자막 생성 시작" or press ⌘R
4. **Monitor** — Watch per-file progress and overall ETA

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Start processing |
| ⌘. | Stop processing |
| Delete | Remove selected files |
| ⌘+Click | Multi-select files |

### Sensitivity Presets

| Preset | Description |
|--------|-------------|
| 민감 (Sensitive) | Catch quiet speech, more permissive |
| 보통 (Normal) | Balanced for general dialogue |
| 정확 (Accurate) | Strict, filters aggressively |

### Supported Formats

**Input:** MP4, MOV, MKV, M4V, AVI, WebM, FLV, M4A, WAV, MP3

**Output:** SRT subtitle files with language postfix (e.g., `video.ja.srt`, `video.ko.srt`)

## Whisper Models

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| Large v3 Turbo (default) | ~1.6GB | Fast | Recommended |
| Large v3 | ~2.9GB | Slow | Best quality |
| Medium | ~1.5GB | Fast | Good |
| Small | ~950MB | Faster | Fair |

## Translation

Supports parallel translation to multiple languages via:
- **Claude Code** — Uses existing subscription (no API key needed)
- **Claude API** — Direct API with model selection (Opus/Sonnet/Haiku)
- **OpenAI API** — GPT-4o / GPT-4.1

Translation includes:
- SRT format validation with retry (up to 3 attempts)
- AI refusal detection
- Existing subtitle skip (won't re-translate)

## License

MIT

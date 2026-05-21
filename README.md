# DemoFlow

DemoFlow is a macOS utility suite with five fixed modules:

1. Recording
2. PiP Camera
3. Screen Drawing
4. Video Cutting
5. Audio Extract (MP3)

For implementation constraints and product rules, see:

- [SPEC.md](/Users/jamie/CodexAi/demoflow/SPEC.md)
- [AGENTS.md](/Users/jamie/CodexAi/demoflow/AGENTS.md)

## Module Overview

### 1) Recording

- QuickTime-style primary-display full-screen recording
- Region recording is intentionally removed
- Main window auto-hides after recording starts
- Uses a dedicated floating recording controller for stop action
- Restores main window on normal stop, startup failure, or unexpected stop

### 2) PiP Camera

- Independent floating camera utility (not a recording side panel)
- Always-on-top preview across Spaces/full-screen contexts
- Manual video/audio device selection (including Continuity Camera when available)
- Preview mute and real-time microphone level feedback
- Aspect ratio: `Auto / 16:9 / 4:3`
- Global hotkey: `⌘⌥P` (toggle show/hide)

### 3) Screen Drawing

- Decoupled drawing module with floating toolbar + transparent canvas
- 6 tools: line, arrow, rectangle, ellipse, cross, check
- 5 color presets: `1 red / 2 yellow / 3 green / 4 blue / 5 black`
- Unified dismissal animation pipeline for clear/hide
- Animation modes: `Random` or `Fixed`
- Fixed effects: `Scatter & Fall`, `Left→Right`, `Right→Left`, `Top→Bottom`, `Bottom→Top`

Current drawing hotkeys:

- `⌃⌥1~5`: select color presets
- `⌘⌥1~6`: select drawing tools
- `⌘⌃S`: toggle drawing overlay show/hide
- `⌘⌃X`: toggle canvas passthrough/drawing interaction

### 4) Video Cutting

- Popup-based smart cutting workflow
- Drag-and-drop or file import for `.mp4/.mov`
- Timeline trimming, multi-range deletion, crop, audio denoise/EQ, export
- Keeps pause state after import/reload (no forced autoplay)

### 5) Audio Extract (MP3)

- Independent fifth module with isolated state channel
- Input sources: local files (`mp4/mov/mkv/webm/mp3`) and online URLs
- Output format: `mp3` only
- Default output root: `~/Movies/DemoFlow/AudioExtract/`
- Subfolder rule: `YYYYMMDD_HHMMSS_<source_tag>/`
- Dependency policy: bundled `ffmpeg/ffprobe` first, bundled `yt-dlp_macos.bundle` only
- Runtime install/decompress for `yt-dlp` is disabled
- Unified failure format: `Cause: ...` and `Next command: ...`
- Success validation requires all checks: file exists, file size > 0, `ffprobe` duration > 0

## State Isolation Rules

- Recording writes only `statusMessage`
- PiP writes only `pipStatusMessage`
- Screen Drawing writes only `drawStatusMessage`
- Audio Extract writes only `AudioExtractViewModel.statusMessage`
- PiP and Screen Drawing actions must not override recording status text
- Audio Extract actions must not override recording/PiP/drawing status text

## Permissions

DemoFlow may request:

- Screen Recording
- Camera
- Microphone

If global hotkeys are unavailable due to system constraints, the app falls back to foreground handling with readable status guidance.

## Build & Checks

From `/Users/jamie/CodexAi/DemoFlow/DemoFlow`:

```bash
Scripts/run_build.sh
Scripts/run_logic_checks.sh
```

## Repo Layout

```text
/Users/jamie/CodexAi/DemoFlow
├── AGENTS.md
├── SPEC.md
├── README.md
├── README.zh-CN.md
├── spec/
└── DemoFlow/
    ├── AGENTS.md
    ├── SPEC.md
    ├── DemoFlow.xcodeproj
    ├── DemoFlow/
    └── Scripts/
```

# DemoFlow

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a>
</p>

<img src="img/logo.png" width="80">

[![CI](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml)

DemoFlow is a macOS utility suite for screen recording, PiP camera, screen drawing, video cutting, and an audio workbench exposed through the existing Audio Extract module.

## Modules

### Recording

![Recording](img/we1.png)

- Full-screen recording on the primary display
- Floating recording controller for stop/pause
- Auto-hide main window during recording

### PiP Camera

![PiP Camera](img/we2.png)

- Independent floating camera preview (always-on-top, works across Spaces)
- Video/audio device selection including Continuity Camera
- Video dubbing, AI voiceover, and subtitle synchronization in the `配音字幕` workbench
- Preview mute and real-time microphone level feedback
- Aspect ratio: Auto / 16:9 / 4:3
- Global hotkey: `⌘⌥P`

### Screen Drawing

![Screen Drawing](img/we3.png)

- Floating toolbar + transparent canvas overlay
- 6 tools: line, arrow, rectangle, ellipse, cross, check
- 5 color presets: red / yellow / green / blue / black
- Unified dismissal animation pipeline

Hotkeys:
- `⌃⌥1~5` — color presets
- `⌘⌥1~6` — drawing tools
- `⌘⌃S` — toggle overlay
- `⌘⌃X` — toggle canvas passthrough

### Video Cutting

![Video Cutting](img/we4.png)

- Drag-and-drop or file import for `.mp4` / `.mov`
- Timeline trimming, single active delete range, crop, audio denoise/EQ, export

### Audio Extract (Module 5)

- The sidebar entry remains **Audio Extract (MP3)**, but the page is now a 3-tab audio workbench:
  - `Audio Extract` — local file / online URL to MP3
  - `Audio Transcode` — local audio batch conversion
  - `Music Trim` — single-file waveform trim and export
- `Audio Transcode` and `Music Trim` are local-file only in the first release
- Audio Extract now defaults to the unified workspace's `Music/` folder
- Audio Transcode and Music Trim still confirm the target file in a save panel, but that panel opens in `Music/` first

## Requirements

- macOS 14.0 or later
- Apple Silicon (arm64) — Intel not supported

## Permissions

DemoFlow requests:

- **Screen Recording** — for screen capture
- **Camera** — for PiP preview and camera recording
- **Microphone** — for recording and PiP audio
- **User-selected files and folders** — for import, export, and manually selected output folders

After you choose a parent folder in **Settings**, DemoFlow creates a `DemoFlow/` workspace there and lazily adds `Recoding / Pip / Draw / Vido / Music` subfolders as needed. Recording, PiP films, and screen-drawing auto captures write directly into their mapped folders. Video Cutting, Audio Transcode, and Music Trim open their save panels in the matching workspace folder first, while Audio Extract defaults to `Music/`. DemoFlow no longer writes user-visible outputs to the app container's `Application Support/DemoFlow/Outputs/` directory. Intermediate files (recording segments, camera `.mov`, framing sidecars, temporary audio working copies) remain in temporary storage and are not user-visible artifacts.

## Download

Pre-built binaries from the latest CI run:

- [**AppStore** build](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml) — without yt-dlp (Mac App Store compatible)
- [**Release** build](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml) — with yt-dlp (full features)

Click the links above, open the latest successful run, and download the artifact from the **Artifacts** section at the bottom.

## Build

Open `DemoFlow.xcodeproj` in Xcode 16+, select the `DemoFlow` scheme, and build.

Or from the project root:

```bash
xcodebuild -project DemoFlow.xcodeproj -scheme DemoFlow -destination 'platform=macOS' build
```

## Dual-Channel Builds

| Configuration | yt-dlp | Distribution |
|---------------|--------|--------------|
| **AppStore** (default) | Excluded | Mac App Store |
| **Release** | Included | Direct download |

See [BUILD_CHANNELS.md](BUILD_CHANNELS.md) for details.

## Repo Layout

```
├── DemoFlow.xcodeproj
├── DemoFlow/
│   ├── DemoFlowApp.swift
│   ├── Views/
│   ├── Models/
│   ├── Services/
│   ├── ViewModels/
│   ├── Lang/
│   ├── Extensions/
│   ├── ThirdParty/
│   └── Assets.xcassets/
├── img/
├── Scripts/
├── BUILD_CHANNELS.md
├── README.md
└── README.zh-CN.md
```

## License

MIT. See [LICENSE](LICENSE) for details.

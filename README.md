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
- Video dubbing, subtitle burning, and local Apple TTS audio replacement in the `配音字幕` workbench
- Preview mute and real-time microphone level feedback
- Aspect ratio: Auto / 16:9 / 4:3
- Global hotkey: `⌘⌥P`

### Screen Drawing

![Screen Drawing](img/we3.png)

- Floating toolbar + transparent canvas overlay
- 6 tools: line, arrow, rectangle, ellipse, text, check
- 5 color presets: red / yellow / green / blue / black
- Unified dismissal animation pipeline
- The hand button at the far right enables annotation movement; click to select, repeatedly click overlaps to cycle layers, then drag the selected annotation. It is off by default so you can keep drawing over annotations

Hotkeys:
- `⌃⌥1~5` — color presets
- `⌘⌥1~6` — drawing tools
- `⌘⌃S` — toggle overlay
- `⌘⌃X` — toggle canvas passthrough

### Video Cutting

![Video Cutting](img/we4.png)

- Drag-and-drop or file import for `.mp4` / `.mov`
- Timeline trimming, playhead splitting, draggable clip reordering, video insertion at the playhead, single active delete range, crop, audio denoise/EQ, export

### Audio Extract (Module 5)

- The sidebar entry remains **Audio Extract (MP3)**, but the page is now a 3-tab audio workbench:
  - `Audio Extract` — local file / online URL to MP3; direct-distribution builds can also save the online video
  - `Audio Transcode` — local audio batch conversion
  - `Music Trim` — single-file waveform trim and export
- `Audio Transcode` and `Music Trim` are local-file only in the first release
- The companion video download for online URLs is external-distribution only; AppStore builds hide this channel
- Audio Extract now defaults to the unified workspace's `Music/` folder
- Audio Transcode and Music Trim still confirm the target file in a save panel, but that panel opens in `Music/` first

### Dubbing & Subtitles (Module 6)

- Four tabs: `Video Dubbing`, `Video Conversion`, `Subtitle Burning`, and `Audio Replacement`
- The four tabs share one video import and temporary session, so the same loaded video and subtitle timeline stay available across the workbench
- Video Conversion accepts `MP4 / MOV / M4V / WebM`, outputs `MP4 / MOV / WebM`, and writes completed files to the unified workspace's `Vido/` folder. A WebM result can be loaded into the shared workbench after converting to MP4/MOV.
- The Video Conversion tab has internal `Format Conversion` and `Remove Watermark` modes. Both use the subtitle-burning layout: configuration on the left, video preview on the right, and a source-audio waveform timeline below.
- Remove Watermark supports multiple manual fixed regions and a true local FFmpeg preview for the current frame. Adding or choosing a region opens the replacement-watermark library, where each region can independently apply a saved PNG and one saved text style; export order is removal, PNG overlays, then text. PNG originals and text styles persist in `Watermarks/Images/` and `watermark-library.json` under the output workspace; PNG imports are limited to 10 MB and 4096 pixels on the longest side, with transparency preserved for accepted files. Region placement remains session-only. It creates an H.264/AAC MP4 in `Vido/`, then automatically reloads it as a clean shared workbench session. It supports MP4/MOV/M4V; convert WebM to MP4/MOV first.
- After timeline edits, use the trailing checkmark icon in the playback row to render and reload the current order as one video. Aspect selection and crop remain locked until this reload completes.
- Subtitle Burning uses local FFmpeg and Whisper.cpp; Audio Replacement uses local Apple TTS

## Subscription

- The primary action is `Purchase` for free users. Existing members can only choose a higher tier, where the action becomes `Upgrade Subscription`; the current and lower tiers are gray and disabled.
- Monthly and yearly memberships show whole days remaining in the subscription window. A lifetime purchase shows `Lifetime SVIP`.
- The 100-day free trial and clear-debug-membership actions exist only in local Debug builds and are excluded from release builds.

## Requirements

- macOS 14.0 or later
- Apple Silicon (arm64) — Intel not supported

## Permissions

DemoFlow requests:

- **Screen Recording** — for screen capture
- **Camera** — for PiP preview and camera recording
- **Microphone** — for recording and PiP audio
- **User-selected files and folders** — for import, export, and manually selected output folders

After you choose a parent folder in **Settings**, DemoFlow creates a `DemoFlow/` workspace there and lazily adds `Recoding / Pip / Draw / Vido / Music` subfolders as needed. The persistent watermark library lives in `Watermarks/`, with PNG files in `Watermarks/Images/` and its index in `watermark-library.json`. Recording, PiP films, and screen-drawing auto captures write directly into their mapped folders. Video Cutting, Audio Transcode, and Music Trim open their save panels in the matching workspace folder first, while Audio Extract defaults to `Music/`. DemoFlow no longer writes user-visible outputs to the app container's `Application Support/DemoFlow/Outputs/` directory. Intermediate files (recording segments, camera `.mov`, framing sidecars, temporary audio working copies) remain in temporary storage and are not user-visible artifacts.

Smart video cutting shows one visible video track. Audio remains logically bound to each video clip without a separate UI track. Each clip keeps its original source start/end time, so clips can be reordered into sequences such as `0-20, 45-55, 20-45, 55-60`. Hovering or holding a thumbnail shows the clip boundaries, drag heads, and source range; dragging moves the current clip. Dropping into the fixed blank area moves it to the end and leaves playable blank time at its old position; the blank area itself is excluded from export.

User-visible exports default to `<feature-code><yyyyMMddHHmmss>.<extension>`; automatic outputs add `-01` on a same-second collision. Save panels prefill this name and still allow manual changes.

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

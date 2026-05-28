# DemoFlow Dual-Channel Build Guide

## Overview

DemoFlow supports two distribution channels via separate Xcode build configurations, controlling whether `yt-dlp` is bundled into the app.

| Channel | Configuration | yt-dlp | Distribution | Purpose |
|---------|--------------|--------|--------------|---------|
| Mac App Store | **AppStore** | Excluded | Mac App Store | Store submission |
| Direct Download | **Release** | Included | Website / other channels | Full functionality |

## Why Dual Builds

Apple MAS review requirement (error 90296): all Mach-O executables inside the app sandbox must be signed with `com.apple.security.app-sandbox` or `com.apple.security.inherit`.

- `ffmpeg` / `ffprobe` can be signed with `com.apple.security.inherit` and run correctly
- `yt-dlp` is a PyInstaller-packaged binary; `codesign` corrupts its internal offsets, causing exit code 133

Therefore the MAS version cannot include `yt-dlp`, but the direct download version can.

## How to Build

### Mac App Store Version (without yt-dlp)

```bash
xcodebuild \
  -project DemoFlow.xcodeproj \
  -scheme DemoFlow \
  -configuration AppStore \
  -destination 'platform=macOS' \
  archive
```

Or in Xcode:
1. Product → Scheme → Edit Scheme
2. Set Build Configuration to **AppStore**
3. Product → Archive

### Direct Download Version (with yt-dlp)

```bash
xcodebuild \
  -project DemoFlow.xcodeproj \
  -scheme DemoFlow \
  -configuration Release \
  -destination 'platform=macOS' \
  archive
```

Or in Xcode:
1. Product → Scheme → Edit Scheme
2. Set Build Configuration to **Release**
3. Product → Archive

## Build Configuration Details

`project.pbxproj` defines two configurations:

- **Release**: no `INCLUDE_YT_DLP` set (script defaults to `YES`)
- **AppStore**: sets `INCLUDE_YT_DLP = NO`

## How It Works

### Signing Script `Scripts/sign_embedded_tools.sh`

The script reads the `INCLUDE_YT_DLP` environment variable:

```
INCLUDE_YT_DLP=YES (or unset)  → copy and sign yt-dlp
INCLUDE_YT_DLP=NO               → skip yt-dlp
```

`ffmpeg` / `ffprobe` are always copied and signed in both configurations.

### Binary Lookup `YtDlpBinaryService.swift`

At runtime the app searches for `yt-dlp` in this order:

1. `Contents/Helpers/yt-dlp` — placed here by the signing script in Release builds
2. `Contents/Helpers/yt-dlp_macos_onedir/yt-dlp_macos` — PyInstaller onedir bundle
3. Other bundle resource paths (Plugins, Resources, etc.)

If none are found, it throws `YtDlpError.notIncluded` with a user-friendly message.

## Feature Differences

| Feature | AppStore | Release |
|---------|:--------:|:-------:|
| Screen Recording | OK | OK |
| PiP Camera | OK | OK |
| Video Cutting (local) | OK | OK |
| Audio Extract (local) | OK | OK |
| Audio Extract (URL) | **N/A** | OK |

In the MAS version, the online URL extraction feature shows an error prompting the user to use local files instead.

## Updating yt-dlp

1. Download the latest standalone binary from [yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases) (`yt-dlp_macos`, not the onedir bundle)
2. Clear quarantine: `xattr -cr <downloaded file>`
3. Replace `DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp`
4. Make executable: `chmod +x DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp`
5. Verify: `./DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp --version`

Only Release builds use this file. AppStore builds are unaffected.

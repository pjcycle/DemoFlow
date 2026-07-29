#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_files=(
  "DemoFlow/Models/SubDubModels.swift"
  "DemoFlow/Models/SubDubTimelineModels.swift"
  "DemoFlow/Services/SubDubExportService.swift"
  "DemoFlow/Services/SubDubSubtitleParser.swift"
  "DemoFlow/Services/SubDubTTSService.swift"
  "DemoFlow/Services/SubDubWorkspaceService.swift"
  "DemoFlow/Services/WhisperTranscriptionService.swift"
  "DemoFlow/ViewModels/SubDubViewModel.swift"
  "DemoFlow/ViewModels/SubtitleBurnViewModel.swift"
  "DemoFlow/ViewModels/AudioReplacementViewModel.swift"
  "Scripts/setup_whisper.sh"
  "DemoFlow/ViewModels/VideoDubbingViewModel.swift"
  "DemoFlow/ViewModels/AIVoiceoverViewModel.swift"
  "DemoFlow/ViewModels/SubtitleSyncViewModel.swift"
  "DemoFlow/Views/Settings/SubDubSettingsView.swift"
)

for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || { print -u2 "Missing required file: $path"; exit 1; }
done

contains() {
  /usr/bin/grep -Eq "$1" "$2"
}

contains 'case subDub' DemoFlow/Models/SettingsSection.swift
contains 'case \.subDub' DemoFlow/ContentView.swift
contains '\.subDub' DemoFlow/Views/Settings/SettingsSidebarView.swift
contains 'SubDubViewModel' DemoFlow/DemoFlowApp.swift
contains 'subdub\.tab\.video_dubbing' DemoFlow/Lang/en.lproj/Localizable.strings
contains 'subdub\.tab\.video_dubbing' DemoFlow/Lang/zh-Hans.lproj/Localizable.strings
contains 'subdub\.tab\.subtitle_burning' DemoFlow/Lang/en.lproj/Localizable.strings
contains 'subdub\.tab\.subtitle_burning' DemoFlow/Lang/zh-Hans.lproj/Localizable.strings
contains 'subdub\.tab\.audio_replacement' DemoFlow/Lang/en.lproj/Localizable.strings
contains 'subdub\.tab\.audio_replacement' DemoFlow/Lang/zh-Hans.lproj/Localizable.strings
contains 'SubtitleStylePreset' DemoFlow/Models/SubDubModels.swift
contains 'Hiragino Sans GB' DemoFlow/Models/SubDubModels.swift
contains 'charenc=UTF-8' DemoFlow/Services/SubDubExportService.swift
contains 'schemaVersion == 1 \|\| document\.schemaVersion == 2' DemoFlow/ViewModels/SubtitleBurnViewModel.swift
contains 'subdub\.subtitle_style\.label' DemoFlow/Lang/en.lproj/Localizable.strings
contains 'subdub\.subtitle_style\.label' DemoFlow/Lang/zh-Hans.lproj/Localizable.strings
contains 'spec/subdub/README\.md' ../AGENTS.md
[[ -f ../spec/subdub/subtitle-burn.md ]] || { print -u2 "Missing subtitle burn specification."; exit 1; }

en_keys=$(/usr/bin/sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' DemoFlow/Lang/en.lproj/Localizable.strings | /usr/bin/sort -u)
zh_keys=$(/usr/bin/sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' DemoFlow/Lang/zh-Hans.lproj/Localizable.strings | /usr/bin/sort -u)
if [[ "$en_keys" != "$zh_keys" ]]; then
  print -u2 "Localization key sets differ between en and zh-Hans."
  exit 1
fi

/usr/bin/git diff --check
print "DemoFlow logic checks passed."

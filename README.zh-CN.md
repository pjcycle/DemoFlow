# DemoFlow

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a>
</p>

[![CI](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml)

DemoFlow 是一款 macOS 实用工具套件，包含屏幕录制、画中画摄像头、屏幕画笔、视频裁剪和音频提取。

## 模块

### 录屏

- 主显示器全屏录制
- 浮动控制器用于暂停/停止
- 录制期间自动隐藏主窗口

### 画中画摄像头

- 独立浮动预览窗口（始终置顶，跨空间/全屏可用）
- 支持视频/音频设备选择，包括 Continuity Camera
- 静音和实时麦克风电平反馈
- 比例：自动 / 16:9 / 4:3
- 全局快捷键：`⌘⌥P`

### 屏幕画笔

- 浮动工具栏 + 透明画布
- 6 种工具：直线、箭头、矩形、椭圆、十字、对勾
- 5 种颜色预设：红 / 黄 / 绿 / 蓝 / 黑
- 统一擦除动画管线

快捷键：
- `⌃⌥1~5` — 颜色预设
- `⌘⌥1~6` — 绘画工具
- `⌘⌃S` — 切换画布显示
- `⌘⌃X` — 切换画布交互模式

### 视频裁剪

- 拖拽或导入 `.mp4` / `.mov`
- 时间轴剪辑、多段删除、裁剪、音频降噪/EQ、导出

### 音频提取

- 从本地文件提取 MP3（`.mp4` / `.mov` / `.mkv` / `.webm` / `.mp3`）
- 在线 URL 提取（完整版）
- 默认输出：`~/Movies/DemoFlow/AudioExtract/`

## 系统要求

- macOS 14.0 或更高
- Apple Silicon (arm64) — 不支持 Intel

## 权限

DemoFlow 会请求以下权限：

- **屏幕录制** — 用于屏幕捕获
- **摄像头** — 用于画中画预览和摄像头录制
- **麦克风** — 用于录制和画中画音频

## 下载

最新 CI 构建产物：

- [**AppStore** 版本](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml) — 不含 yt-dlp（兼容 Mac App Store）
- [**Release** 版本](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml) — 含 yt-dlp（完整功能）

点击链接，打开最新成功的运行记录，从底部 **Artifacts** 区域下载。

## 构建

在 Xcode 16+ 中打开 `DemoFlow.xcodeproj`，选择 `DemoFlow` scheme 并构建。

或在项目根目录执行：

```bash
xcodebuild -project DemoFlow.xcodeproj -scheme DemoFlow -destination 'platform=macOS' build
```

## 双渠道构建

| 配置 | yt-dlp | 分发渠道 |
|------|--------|---------|
| **AppStore**（默认） | 不包含 | Mac App Store |
| **Release** | 包含 | 直接下载 |

详见 [BUILD_CHANNELS.md](BUILD_CHANNELS.md)。

## 许可

MIT。详见 [LICENSE](LICENSE)。

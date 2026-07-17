# DemoFlow

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a>
</p>

<img src="img/logo.png" width="80">

[![CI](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml)

DemoFlow 是一款 macOS 实用工具套件，包含屏幕录制、画中画摄像头、屏幕画笔、视频裁剪，以及通过既有“音频提取（MP3）”入口承载的统一音频工具台。
同时提供独立的“配音字幕”工作台，包含视频配音、AI口播和字幕同步。

## 模块

### 录屏

![录屏](img/we1.png)

- 主显示器全屏录制
- 浮动控制器用于暂停/停止
- 录制期间自动隐藏主窗口

### 画中画摄像头

![画中画摄像头](img/we2.png)

- 独立浮动预览窗口（始终置顶，跨空间/全屏可用）
- 支持视频/音频设备选择，包括 Continuity Camera
- 静音和实时麦克风电平反馈
- 比例：自动 / 16:9 / 4:3
- 全局快捷键：`⌘⌥P`

### 屏幕画笔

![屏幕画笔](img/we3.png)

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

![视频裁剪](img/we4.png)

- 拖拽或导入 `.mp4` / `.mov`
- 时间轴剪辑、单活动删除区间、裁剪、音频降噪/EQ、导出

### 音频提取（第 5 模块）

- 侧栏入口名称仍为 **音频提取（MP3）**，但页面已升级为 3 个 Tab 的统一音频工具台：
  - `音频提取`：本地文件 / 在线 URL 到 MP3
  - `音频转换`：本地音频批量格式转换
  - `音乐裁切`：单文件波形裁切与导出
- `音频转换` 与 `音乐裁切` 首发仅支持本地文件
- 音频提取默认写入统一工作区下的 `Music/`
- 音频转换与音乐裁切仍保留保存面板确认，但默认打开 `Music/`

## 系统要求

- macOS 14.0 或更高
- Apple Silicon (arm64) — 不支持 Intel

## 权限

DemoFlow 会请求以下权限：

- **屏幕录制** — 用于屏幕捕获
- **摄像头** — 用于画中画预览和摄像头录制
- **麦克风** — 用于录制和画中画音频
- **用户选择的文件与目录** — 用于导入、导出和手动选择输出目录

用户在 **设置** 中选择一个父目录后，DemoFlow 会在其中创建 `DemoFlow/` 根目录，并按需生成 `Recoding / Pip / Draw / Vido / Music` 子目录。录屏、PiP 录像、屏幕画图自动截图会直接写入对应子目录；视频剪切、音频转换、音乐裁切的保存面板会默认打开对应子目录，最终路径仍以用户确认结果为准；音频提取默认写入 `Music/`。DemoFlow 不再将用户可见的音频成品写到 App 沙盒容器的 `Application Support/DemoFlow/Outputs/` 目录。中间产物（录屏分段、摄像头 `.mov`、framing sidecar、临时音频工作副本）继续保留在系统临时目录，不属于用户可见产物。

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

## 仓库结构

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

## 许可

MIT。详见 [LICENSE](LICENSE)。

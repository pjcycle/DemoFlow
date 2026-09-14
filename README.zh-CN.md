# DemoFlow

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a>
</p>

<img src="img/logo.png" width="80">

[![CI](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/pjcycle/DemoFlow/actions/workflows/ci.yml)

DemoFlow 是一款 macOS 实用工具套件，包含屏幕录制、画中画摄像头、屏幕画笔、视频裁剪，以及通过既有“音频提取（MP3）”入口承载的统一音频工具台。
同时提供独立的“配音字幕”工作台，包含视频配音、视频转换、字幕烧制和音频替换；四个页面共用同一视频导入会话。

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
- 拖动悬浮 PiP 时保持最后一帧稳定显示，停止移动后自动恢复实时画面
- 比例：自动 / 16:9 / 4:3
- 全局快捷键：`⌘⌥P`

### 屏幕画笔

![屏幕画笔](img/we3.png)

- 浮动工具栏 + 透明画布
- 6 种工具：直线、箭头、矩形、椭圆、文字、对勾
- 5 种颜色预设：红 / 黄 / 绿 / 蓝 / 黑
- 统一擦除动画管线
- 工具条最右侧的手势按钮用于开启已有标注移动；单击选中，重叠处连续单击循环选层，再拖动选中标注。默认关闭，可继续在标注上绘制
- 文字工具替换原十字图标：点击画布后支持多行输入，回车提交、Shift-回车换行、Esc 取消；提交后的文字可按普通标注移动

快捷键：
- `⌃⌥1~5` — 颜色预设
- `⌘⌥1~6` — 绘画工具
- `⌘⌃S` — 切换画布显示
- `⌘⌃X` — 切换画布交互模式

### 视频裁剪

![视频裁剪](img/we4.png)

- 拖拽或导入 `.mp4` / `.mov`
- 时间轴剪辑、播放头截断、片段拖动重排、播放头位置插入视频、单活动删除区间、裁剪、音频降噪/EQ、导出

### 音频提取（第 5 模块）

- 侧栏入口名称仍为 **音频提取（MP3）**，但页面已升级为 3 个 Tab 的统一音频工具台：
  - `音频提取`：本地文件 / 在线 URL 到 MP3；外部分发版本可同时保存在线视频
  - `音频转换`：本地音频批量格式转换
  - `音乐裁切`：单文件波形裁切与导出
- `音频转换` 与 `音乐裁切` 首发仅支持本地文件
- 在线 URL 的视频伴随下载仅存在于外部分发版本，App Store 版本不展示该通道
- 音频提取默认写入统一工作区下的 `Music/`
- 音频转换与音乐裁切仍保留保存面板确认，但默认打开 `Music/`

### 配音字幕（第 6 模块）

- 页面固定包含 `视频配音 / 视频转换 / 字幕烧制 / 音频替换` 四个 Tab
- 四个 Tab 共用同一视频导入与临时会话，切换页面后仍使用同一载入视频和字幕时间轴
- 视频转换支持 `MP4 / MOV / M4V / WebM` 输入和 `MP4 / MOV / WebM` 输出，成品自动写入统一工作区的 `Vido/`；WebM 转为 MP4/MOV 后可载入四 Tab 共享会话
- 视频转换页在左侧配置顶部提供“格式转换 / 水印去除”内部模式；两种模式都按字幕烧制风格提供左侧配置、右侧视频预览和底部源音轨波形
- 水印去除支持多个手动固定区域与本地 FFmpeg 当前帧真实预览；新增或点击区域会打开替换水印库，每个区域可独立应用已保存的静态 PNG 和文字样式，整段处理顺序固定为去除 -> PNG -> 文字。PNG 原图与文字样式持久化在输出工作区的 `Watermarks/Images/` 和 `watermark-library.json`，PNG 导入限制为不超过 `10MB` 且最长边不超过 `4096` 像素，合规图片保留透明通道，区域位置仅属于当前视频会话。成品以 H.264/AAC MP4 写入 `Vido/` 后自动重新载入为干净的共享会话；仅支持 MP4/MOV/M4V，WebM 需先转换为 MP4/MOV
- 字幕烧制使用本地 FFmpeg 与 Whisper.cpp，音频替换使用本地 Apple TTS

## 订阅

- 免费状态的主操作显示“购买”；已有订阅时只允许选择更高档方案并显示“升级订阅”，当前方案和更低档方案会灰色禁用，不支持降级。
- 月付和年付会员在订阅弹窗中显示剩余整天数；买断显示“永久SVIP”。
- 当前版本不提供独立免费试用，仅支持月付、年付和买断。月付与年付通过 StoreKit 自动续订，买断为 Non-Consumable；购买与恢复均通过 StoreKit 2 完成。
- 正常成交价使用 App Store storefront 的本地化货币，中国区显示人民币；划线营销原价固定显示美元。

### 本地调试订阅

本地调试分为两个 Scheme：`DemoFlowLocalStoreKit` 只用于本地真实购买/恢复，不显示诊断、不提供清空按钮；`DemoFlowLocalStoreKitTestReset` 用于免费态录屏和重置，购买后可查看并清理 Debug 信息。两者都不上传；`.storekit` 交易历史需在 Xcode Transaction Manager 中删除。

项目提供两个本地 Scheme：`DemoFlowLocalStoreKit` 用于真实本地 StoreKit 购买和恢复，不含诊断或清空按钮；`DemoFlowLocalStoreKitTestReset` 用于免费态录屏与界面测试，包含诊断和清空调试信息入口。重置入口只清理 App 自身数据，不会编译到 Sandbox、TestFlight 或 App Store 包。

### Scheme 与分发规则

`DemoFlowLocalStoreKit` 仅用于本地真实 StoreKit 购买和恢复；`DemoFlowLocalStoreKitTestReset` 仅用于 Debug 免费态录屏、诊断和清空 App 数据。若仍显示会员，需在 Xcode Transaction Manager 删除 `.storekit` 交易。`DemoFlowSandbox` 只做本机 Sandbox 检查，`DemoFlowTestFlight` 用于上传 TestFlight，`DemoFlow` 用于正式 App Store 提交（Archive 固定 `AppStore`）；这三个分发 Scheme 均无诊断信息和清空调试按钮。


## 系统要求

- macOS 14.0 或更高
- Apple Silicon (arm64) — 不支持 Intel

## 权限

DemoFlow 会请求以下权限：

- **屏幕录制** — 用于屏幕捕获
- **摄像头** — 用于画中画预览和摄像头录制
- **麦克风** — 用于录制和画中画音频
- **用户选择的文件与目录** — 用于导入、导出和手动选择输出目录

用户在 **设置** 中选择一个父目录后，DemoFlow 会在其中创建 `DemoFlow/` 根目录，并按需生成 `Recoding / Pip / Draw / Vido / Music` 子目录。持久化水印库位于 `Watermarks/`，PNG 图片存于 `Watermarks/Images/`，索引文件为 `watermark-library.json`。录屏、PiP 录像、屏幕画图自动截图会直接写入对应子目录；视频剪切、音频转换、音乐裁切的保存面板会默认打开对应子目录，最终路径仍以用户确认结果为准；音频提取默认写入 `Music/`。DemoFlow 不再将用户可见的音频成品写到 App 沙盒容器的 `Application Support/DemoFlow/Outputs/` 目录。中间产物（录屏分段、摄像头 `.mov`、framing sidecar、临时音频工作副本）继续保留在系统临时目录，不属于用户可见产物。

智能裁切时间线只显示视频轨，音频不单独显示但跟随视频片段逻辑绑定。每个片段保留原始视频开始/结束时间，因此可以重排成 `0-20、45-55、20-45、55-60`。鼠标悬停或按住缩略图时会显示片段边界线、拖动头和原始起止时间，按住即可移动当前片段。把片段拖到右侧固定空白区会移动到末尾，原位置保留可播放但无视频画面的空白；空白区本身不参与导出。相邻片段显示断点线与剪刀标记。

删除区间或右键片段点击垃圾桶，只会删除画面并保留原时间线位置为空白，不会立即重载；点击播放控制行末尾的打勾图标，才会按最终时间线生成并重载为单一视频。重载完成前，比例选择和画面裁切会锁定。

所有用户可见导出默认采用 `<功能代号><yyyyMMddHHmmss>.<扩展名>`；自动导出在同秒冲突时追加 `-01`，保存面板预填该名称且仍允许手动修改。

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

# DemoFlow

DemoFlow 是一个 macOS 工具集，固定五个模块：

1. 录屏
2. PiP 摄像
3. 屏幕画图
4. 视频剪切
5. 音频提取（MP3）

产品约束与实现规则请参考：
- [SPEC.md](/Users/jamie/CodexAi/DemoFlow/SPEC.md)
- [AGENTS.md](/Users/jamie/CodexAi/DemoFlow/AGENTS.md)

## 模块说明

### 1) 录屏

- 对齐 QuickTime 风格的主屏整屏录制
- 已移除区域录制能力
- 点击开始录制后主窗口自动隐藏
- 通过独立悬浮控制器执行停止
- 正常停止、启动失败、异常停止后都自动恢复主窗口

### 2) PiP 摄像

- 独立悬浮摄像工具（不是录屏附属面板）
- 支持跨 Space / 全屏场景前置显示
- 支持手动选择视频/音频设备（可用时支持 Continuity Camera）
- 支持预览静音与实时麦克风电平
- 比例支持：`自动 / 16:9 / 4:3`
- 全局热键：`⌘⌥P`（显示/收起切换）

### 3) 屏幕画图

- 解耦独立模块：置顶工具条 + 透明画布
- 6 个工具：线条、箭头、矩形、圆形、错、对
- 5 个固定颜色：`1 红 / 2 黄 / 3 绿 / 4 蓝 / 5 黑`
- 清空与收起统一走消隐动画管线
- 动画模式：`随机` / `固定`
- 固定效果：`散了掉落 / 左→右 / 右→左 / 上→下 / 下→上`

当前画图快捷键：

- `⌃⌥1~5`：选择颜色
- `⌘⌥1~6`：选择工具
- `⌘⌃S`：显示/收起画图
- `⌘⌃X`：画布穿透/恢复绘制切换

### 4) 视频剪切

- 弹窗式智能剪切流程
- 支持拖拽或文件导入 `.mp4/.mov`
- 支持时间轴剪切、多段删除、画面裁切、声音降噪/均衡器、导出
- 导入与重载后保持暂停态，不强制自动播放

### 5) 音频提取（MP3）

- 独立第 5 模块，状态通道解耦
- 输入来源：本地文件（`mp4/mov/mkv/webm/mp3`）与在线 URL
- 输出格式固定：`mp3`
- 默认输出根目录：`~/Movies/DemoFlow/AudioExtract/`
- 子目录规则：`YYYYMMDD_HHMMSS_<source_tag>/`
- 依赖策略：`ffmpeg/ffprobe` 内置优先，`yt-dlp` 仅支持内置 `yt-dlp_macos.bundle`
- 明确禁用运行时下载/解压/安装 `yt-dlp`
- 失败提示统一：`原因: ...` + `下一步命令: ...`
- 成功前必须通过三重校验：文件存在、文件大小 > 0、`ffprobe` 时长 > 0

## 状态隔离规则

- 录屏状态仅写 `statusMessage`
- PiP 状态仅写 `pipStatusMessage`
- 画图状态仅写 `drawStatusMessage`
- 音频提取状态仅写 `AudioExtractViewModel.statusMessage`
- PiP 与画图操作不覆写录屏状态文案
- 音频提取操作不覆写录屏/PiP/画图状态文案

## 权限说明

DemoFlow 可能请求以下系统权限：

- 屏幕录制
- 摄像头
- 麦克风

如果全局热键因系统限制不可用，应用会降级到前台热键处理，并给出可读状态提示。

## 构建与自检

在 `/Users/jamie/CodexAi/DemoFlow/DemoFlow` 目录执行：

```bash
Scripts/run_build.sh
Scripts/run_logic_checks.sh
```

## 仓库结构

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

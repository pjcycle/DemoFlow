# DemoFlow 双渠道构建说明

## 概述

DemoFlow 支持两种分发渠道的构建方式，使用不同的 Xcode Build Configuration，控制是否将 yt-dlp 打包进 App。

| 渠道 | Build Configuration | yt-dlp | 分发方式 | 用途 |
|------|---------------------|--------|---------|------|
| Mac App Store | **AppStore** | 不包含 | Mac App Store | 上架审核 |
| 直接下载 | **Release** | 包含 | 官网 / 其他渠道 | 完整功能 |

## 为什么需要双构建

Apple MAS 审核要求 (错误码 90296)：App 沙盒内的所有 Mach-O 可执行文件都必须签名并带有 `com.apple.security.app-sandbox` 或 `com.apple.security.inherit` 权限。

- ffmpeg / ffprobe 可以使用 `com.apple.security.inherit` 正常签名并运行
- yt-dlp 是 PyInstaller 打包的二进制，codesign 会破坏其内部偏移，导致退出码 133，无法通过签名

因此 MAS 版本不能包含 yt-dlp，但直接下载版本可以。

## 如何构建

### Mac App Store 版本 (不含 yt-dlp)

```bash
xcodebuild \
  -project DemoFlow.xcodeproj \
  -scheme DemoFlow \
  -configuration AppStore \
  -destination 'platform=macOS' \
  archive
```

或在 Xcode 中：
1. Product → Scheme → Edit Scheme
2. 将 Build Configuration 改为 **AppStore**
3. Product → Archive

### 直接下载版本 (含 yt-dlp)

```bash
xcodebuild \
  -project DemoFlow.xcodeproj \
  -scheme DemoFlow \
  -configuration Release \
  -destination 'platform=macOS' \
  archive
```

或在 Xcode 中：
1. Product → Scheme → Edit Scheme
2. 将 Build Configuration 改为 **Release**
3. Product → Archive

## 构建配置详情

`project.pbxproj` 中定义了两个 Build Configuration：

- **Release**: 不包含 `INCLUDE_YT_DLP` 设置（脚本默认为 `YES`）
- **AppStore**: 设置 `INCLUDE_YT_DLP = NO`

## 工作原理

### 签名脚本 `Scripts/sign_embedded_tools.sh`

脚本通过读取 `INCLUDE_YT_DLP` 环境变量决定行为：

```
INCLUDE_YT_DLP=YES (或未设置)  → 复制并签名 yt-dlp
INCLUDE_YT_DLP=NO               → 跳过 yt-dlp
```

所有构建中 ffmpeg / ffprobe 始终被复制和签名。

### 二进制查找路径 `YtDlpBinaryService.swift`

App 启动时按以下顺序查找 yt-dlp：

1. `Contents/Helpers/yt-dlp` — Release 构建中签名脚本放置的位置
2. `Contents/Helpers/yt-dlp_macos_onedir/yt-dlp_macos` — PyInstaller onedir bundle
3. 其他 bundle 资源路径 (Plugins、Resources 等)

全部找不到时抛出 `YtDlpError.notIncluded`，错误提示：
> "yt-dlp is not included in this build. Online URL extraction is unavailable; please use local file input."

## 功能差异

| 功能 | AppStore 版本 | Release 版本 |
|------|:------------:|:-----------:|
| 屏幕录制 | OK | OK |
| PiP 摄像头 | OK | OK |
| 视频裁切 (本地文件) | OK | OK |
| 音频提取 (本地文件) | OK | OK |
| 音频提取 (在线 URL) | **不可用** | OK |

MAS 版本中，音频提取的在线 URL 输入功能会显示错误提示，引导用户使用本地文件输入。

## 更新 yt-dlp 版本

1. 从 [yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases) 下载最新的 `yt-dlp_macos` (独立二进制，非 onedir)
2. 清理隔离属性：`xattr -cr <下载的文件>`
3. 替换 `DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp`
4. 给可执行权限：`chmod +x DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp`
5. 验证：`./DemoFlow/ThirdParty/yt-dlp/arm64/yt-dlp --version`

只有 Release 构建会使用此文件。AppStore 构建不受影响。

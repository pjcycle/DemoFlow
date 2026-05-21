# ThirdParty 目录说明（DemoFlow）

本目录用于存放 **随 App 一起打包** 的第三方二进制资源，避免运行时依赖用户本机环境。

## 1. 当前资源与用途

- `ffmpeg/arm64/ffmpeg`：音视频转码、裁切、提取主程序（视频剪切/音频提取使用）。
- `ffmpeg/arm64/ffprobe`：媒体探测程序（用于时长/轨道校验）。
- `yt-dlp/arm64/yt-dlp_macos_onedir/yt-dlp_macos`：URL 下载与抽取（音频提取在线 URL 使用）。
- `yt-dlp/arm64/yt-dlp`：历史脚本文件，兼容保留；生产链路以 `yt-dlp_macos_onedir/yt-dlp_macos` 为准。

## 2. 官方主页（下载入口）

- FFmpeg 官网：[https://ffmpeg.org/](https://ffmpeg.org/)
- FFmpeg 下载页：[https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)
- yt-dlp 项目主页：[https://github.com/yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp)
- yt-dlp Releases：[https://github.com/yt-dlp/yt-dlp/releases](https://github.com/yt-dlp/yt-dlp/releases)
- yt-dlp macOS bundle（latest）：  
  [https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip)

## 3. 如何更新到最新三方资源（建议流程）

1. 先在上面主页确认最新稳定版本与系统架构（当前项目固定 `macOS arm64`）。
2. 下载并替换文件到以下固定路径（**文件名不要改**）：
   - `ffmpeg/arm64/ffmpeg`
   - `ffmpeg/arm64/ffprobe`
   - `yt-dlp/arm64/yt-dlp_macos_onedir/yt-dlp_macos`
3. 给可执行权限：
   - `chmod +x ffmpeg/arm64/ffmpeg ffmpeg/arm64/ffprobe yt-dlp/arm64/yt-dlp_macos_onedir/yt-dlp_macos`
4. 清理下载隔离属性（避免沙盒/签名环境执行异常）：
   - `xattr -dr com.apple.quarantine ffmpeg/arm64/ffmpeg ffmpeg/arm64/ffprobe yt-dlp/arm64/yt-dlp_macos_onedir`
5. 本地校验版本：
   - `./ffmpeg/arm64/ffmpeg -version | head -1`
   - `./ffmpeg/arm64/ffprobe -version | head -1`
   - `./yt-dlp/arm64/yt-dlp_macos_onedir/yt-dlp_macos --version`
6. 回到项目根目录编译检查：
   - `xcodebuild -project DemoFlow.xcodeproj -scheme DemoFlow -destination 'platform=macOS' build`

## 4. Xcode 打包注意事项（非常重要）

1. `yt-dlp_macos_onedir` 必须作为**完整目录**拷贝进资源，不要把内部 `_internal` 文件逐个扁平加入 `Copy Bundle Resources`。
2. 若把 `_internal` 内部文件扁平拷贝到资源根，可能触发重复产物错误（如 `top_level.txt` duplicate output file）。
3. 音频提取 URL 链路只支持内置 bundle；禁止改回运行时下载/解压/安装模式。

## 5. 当前已验证版本（2026-05-15）

- `ffmpeg`：`6.1.1`
- `ffprobe`：`6.1.1`
- `yt-dlp_macos`：`2026.03.17`

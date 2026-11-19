<p align="center">
  <img src="assets/images/app_logo.webp" width="120" alt="什锦铺">
</p>

<h1 align="center">什锦铺 · iOS 修复版</h1>

<p align="center">
  <strong>小说 · 听书 · 短剧 · 漫剧 · 漫画</strong><br>
  本仓库是 <a href="https://github.com/ch6vip/novel-sound">ch6vip/novel-sound</a> 的社区 fork，主要面向 iOS。
</p>

<p align="center">
  <a href="https://github.com/ch6vip/novel-sound"><img src="https://img.shields.io/badge/upstream-ch6vip%2Fnovel--sound-E89B35" alt="上游仓库"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/platform-iOS-lightgrey" alt="iOS">
</p>

---

## 原项目

- 上游仓库：**https://github.com/ch6vip/novel-sound**
- 旧地址：`https://github.com/ch6vip/fqapp`（已 301 到新地址，同一个仓库）
- 上游作者：`ch6vip`
- 协议：**GPL-3.0**

“fqapp → novel-sound”只是 GitHub 仓库改名，repo id 没变；`fqapp` 仍然出现在 Android 包名、Windows 产物和 Dart/Rust 包名里。

本仓库 fork 自上游，保留完整 Git 历史，代码改动以 PR 形式提交回上游（见 [PR #429](https://github.com/ch6vip/novel-sound/pull/429)）。

## 这个 fork 改了什么

主播放故障（2026-11-16 起短剧/漫剧空 body）采用上游 **PR #425 的 V5 签名修复**，本 fork 跟随上游，不再使用临时的 `x-medusa: 1` 方案。

在此之上，本 fork 增加了：

| 方向 | 内容 |
|---|---|
| iOS 播放 | 播放通道接到进程内 `media_kit`，新增 `IosPlatform.install()`；短剧/漫剧改用纹理渲染；补亮屏锁 |
| iOS 导入 | `UIDocumentPicker` 只认 UTI，TXT/EPUB 改用 `public.plain-text` / `org.idpf.epub-container`，修复“选不中文件” |
| iOS 登录/导出 | WKWebView 读取番茄登录 Cookie；导出文件走系统分享面板；后台听书 |
| iOS 加密媒体 | Rust `desktop_media` / `desktop_fetch` 增加 `target_os = "ios"`，`build.rs` 为 iOS 编译 C 加密源 |
| VVC 兜底 | 纯 `bytevc2`(VVC) 剧集向上游请求 `codec_type=1` 的 H.265 流并缓存，作者明确不做这块 |
| 搜索 | 分类标签筛选 + 搜索结果页按状态/字数二次筛选 |
| 书架（2026-11-18） | 书架 tab 收全部媒介，新增「全部 / 小说 / 漫画 / 短剧 / 漫剧 / 听书」筛选；底部四个入口常驻 |
| 工程 | Android 共存包开关、iOS 构建脚本与文档、`fixes.patch` |

详细改动、验证记录和已知限制见：

- [修复说明.md](修复说明.md)
- [变更说明_2026-11-18.md](变更说明_2026-11-18.md)
- [fixes.patch](fixes.patch)

## 平台说明

> **本 fork 目前只维护 iOS。Android 和 Windows 暂不出包、不做实机验证。**

- **iOS**：主目标平台。构建、签名、安装见 [IOS.md](IOS.md)。
- **Android / Windows**：源码和构建脚本仍在仓库里，方便对照与后续合并；本 fork 不保证可用，也不提供 APK/EXE。

## iOS 构建（摘要）

完整步骤、签名和踩坑记录见 [IOS.md](IOS.md)。

```bash
# 1. Rust 静态库（产出 ios/Frameworks/libfqapi_core.a）
./scripts/build_rust_ios.sh

# 2. Pods（首次会下载 mpv/libmpv，需要能访问外网）
cd ios && pod install && cd ..

# 3. 编包（不签名）
flutter build ios --release --no-codesign
# → build/ios/iphoneos/Runner.app

# 4. 签名导出 ipa（用自己的证书/描述文件）
#    参考 IOS.md 的 codesign / xcodebuild -exportArchive 段落
```

环境版本：Flutter 3.50.0 / Dart 3.14.0、Rust stable、Xcode 16+、CocoaPods。

## 文档索引

| 文档 | 内容 |
|---|---|
| [IOS.md](IOS.md) | iOS 构建、签名、安装、常见错误 |
| [WINDOWS.md](WINDOWS.md) | Windows 构建说明（本 fork 不再出包，仅作参考） |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 上游开发文档 |
| [修复说明.md](修复说明.md) | 合并版的完整改动与验证 |
| [变更说明_2026-11-18.md](变更说明_2026-11-18.md) | 书架筛选、底部导航常驻 |

## 免责声明

本项目仅用于学习与技术交流，不提供、不存储任何音视频或文字内容；所有内容均来自第三方接口，版权归原作者所有。请勿用于商业用途，并在试用后 24 小时内删除。使用本软件产生的任何后果由使用者自行承担。

代码以 **GPL-3.0** 发布，与上游一致。

import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// 桌面和 iOS 走进程内的 media_kit —— iOS 上没有原生播放器实现，通道由
/// `IosPlatform` 接到 Dart 侧，能力等同 Windows 桌面版（没有悬浮窗、画中画
/// 与后台锁屏控制）。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        isWindowsDesktop);

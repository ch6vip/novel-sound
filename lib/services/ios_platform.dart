import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_log.dart';
import 'desktop_platform.dart';
import 'platform_channel.dart';

/// 是否跑在 iOS / iPadOS 真机与模拟器上。
bool get isIOSDevice =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// iOS 的进程内平台适配层。
///
/// Android 那套 `fqapp/native_player` 通道在 iOS 上没有原生实现；这里把同一
/// 份通道契约接到 Dart 侧的 media_kit 播放器（和 Windows/Linux 共用
/// [DesktopPlatform]），于是播放页、短剧页、听书页的代码一行都不用改，
/// 只是能力收敛到桌面版那一档：能播、能暂停/拖动/倍速/音量、没有悬浮窗。
///
/// 没有接入的回放能力（画中画、后台音频的锁屏控制、直播）走的是和桌面一样的
/// 「不支持」分支，不会把失败说成成功。
class IosPlatform {
  IosPlatform._();

  static Future<void> install() async {
    // 播放器事件（created/position/playing/…）由 DesktopPlatform 合成，
    // 其余通道仍旧交回真正的 MethodChannel，缺实现时照常抛
    // MissingPluginException，与没装适配层之前一致。
    PlatformChannels.events = (name) {
      if (name == 'fqapp/native_player/events' ||
          name == 'fqapp/reader/events') {
        return DesktopPlatform.instance.events(name);
      }
      return EventChannel(name).receiveBroadcastStream();
    };
    PlatformChannels.invoke = (channel, method, arguments) async {
      // 书架备份 / 本地书籍 / 下载导出在桌面上由 file_selector + path_provider
      // 实现，iOS 上这两套插件都有（file_selector_ios 提供系统文件选择器），
      // 直接复用桌面实现即可；导出没有「另存为」，由 IosFilesBridge 换成分享面板。
      if (channel == 'fqapp/library_backup' || channel == 'fqapp/local_books') {
        return DesktopPlatform.instance.invoke(channel, method, arguments);
      }
      if (channel == 'fqapp/native_player') {
        // 亮屏锁：Windows 走 kernel32，Linux 走会话桥，iOS 用 wakelock_plus。
        if (method == 'setKeepScreenOn') {
          final args = arguments is Map ? arguments : const {};
          try {
            if (args['on'] == true) {
              await WakelockPlus.enable();
            } else {
              await WakelockPlus.disable();
            }
          } catch (error, stack) {
            AppLog.w('ios-player', '亮屏锁切换失败', error: error, stack: stack);
          }
          return null;
        }
        // SMTC / 悬浮窗是 Windows、Android 专有，iOS 上没有等价物。
        if (method == 'startListenForeground' ||
            method == 'stopListenForeground') {
          return null;
        }
        return DesktopPlatform.instance.invoke(channel, method, arguments);
      }
      return MethodChannel(channel).invokeMethod<dynamic>(method, arguments);
    };
  }

  /// media_kit 的 `Video` 需要拿到它自己的 `VideoController`，不能像 Android
  /// 那样直接 `Texture(textureId:)`；表面的搬运交给 [DesktopPlatform]。
  static Widget videoSurface(int id, {Key? key}) =>
      DesktopPlatform.instance.videoSurface(id, key: key);
}

// #318：冷启动的两层全屏等待提示被弱化。
//
// 成功路径上，AppBootstrap（本地数据）与 RootShell（本地服务）都不再整屏
// 遮罩：界面先出来，初始化在后台静默完成，等待反馈交给页面内的骨架。
// 失败路径必须原样保留：原因、重试，以及服务面板/离线阅读入口。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';

void main() {
  testWidgets('本地数据就绪前只有骨架，没有整屏等待提示', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppBootstrap(
          initializer: () => pending.future,
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pump();

    // 等待文案与转圈都消失了，只剩骨架占住版式。
    expect(find.text('正在读取本地数据…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(HomeSkeleton), findsOneWidget);
    expect(find.text('ready'), findsNothing);

    pending.complete();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.byType(HomeSkeleton), findsNothing);
  });

  testWidgets('本地服务还没起来时界面先出来，不再整屏遮罩', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(backendStarter: () => pending.future),
        ),
      ),
    );
    await tester.pump();

    // 首页已经挂上来，等待反馈由页面内的骨架承担。
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('正在启动本地服务...'), findsNothing);
    expect(find.text('启动失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地服务启动失败仍保留错误页与重试、服务面板入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              throw StateError('核心起不来');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('启动失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('服务面板'), findsOneWidget);
    expect(find.text('离线阅读'), findsOneWidget);
    // 失败页整屏接管，首页不再挂在下面。
    expect(find.byType(HomePage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

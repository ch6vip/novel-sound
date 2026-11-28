import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/plugin_home_page.dart';
import 'package:fqapp/services/novel_plugins.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_plugins_test.dart' show frame, metadata;

void main() {
  for (final style in AppThemeStyle.values) {
    testWidgets(
      '${style.name} home remembers the selected source and its channels',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Widget app(Widget home) => MaterialApp(
          theme: ThemeData(extensions: [AppStyleTokens.forStyle(style)]),
          home: home,
        );
        SharedPreferences.setMockInitialValues({});
        final calls = <(String?, String?)>[];
        final oldResponse = Completer<Map<String, Object>>();
        final registry = NovelPluginRegistry(
          supportsZipPackages: true,
          bridge: (action, args, _) async {
            if (action == 'list') {
              return metadata([
                {
                  'sourceId': 'fanqie',
                  'version': '1.0.6',
                  'publisher': 'fanqie-key',
                  'protocol': 'native-v1',
                  'bookstoreFeed': true,
                },
                {
                  'sourceId': 'qimao',
                  'name': '七猫小说',
                  'version': '1.0.0',
                  'publisher': 'qimao-key',
                  'protocol': 'json-v1',
                  'capabilities': {'home': 1},
                  'channels': [
                    {'id': 'popular', 'title': '七猫推荐'},
                    {'id': 'complete', 'title': '七猫完本'},
                  ],
                },
              ]);
            }
            calls.add((args['sourceId'], args['path']));
            if (args['sourceId'] == 'fanqie') {
              return frame(await oldResponse.future);
            }
            return frame({
              'items': [
                {'bookId': '42', 'title': '七猫书籍'},
              ],
            });
          },
        );
        addTearDown(registry.dispose);
        await tester.pumpWidget(app(PluginHomePage(registry: registry)));
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('番茄'), findsOneWidget);
        expect(find.text('小说'), findsOneWidget);
        final sourceButton = find.byKey(const Key('home_plugin_source'));
        final referenceWidth = tester.getSize(sourceButton).width;

        await tester.tap(sourceButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 320));
        await tester.tap(
          find.ancestor(
            of: find.text('七猫小说'),
            matching: find.byWidgetPredicate(
              (widget) => widget is CheckedPopupMenuItem<String>,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(sourceButton).width, referenceWidth);
        expect(find.text('七猫推荐'), findsOneWidget);
        expect(find.text('七猫书籍'), findsOneWidget);
        expect(find.text('小说'), findsNothing);
        expect(calls, contains(('qimao', '/v1/home/popular')));

        oldResponse.complete({'data': {}});
        await tester.pumpAndSettle();
        expect(find.text('七猫书籍'), findsOneWidget);

        await tester.tap(find.byKey(const Key('home_manage_channels')));
        await tester.pumpAndSettle();
        tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorderItem!(0, 1);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(
          tester.getCenter(find.text('七猫完本')).dx,
          lessThan(tester.getCenter(find.text('七猫推荐')).dx),
        );

        await tester.tap(find.byKey(const Key('home_manage_channels')));
        await tester.pumpAndSettle();
        final switchRow = find.ancestor(
          of: find.text('七猫推荐').last,
          matching: find.byType(ListTile),
        );
        await tester.tap(
          find.descendant(of: switchRow, matching: find.byType(Switch)),
        );
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(find.text('七猫推荐'), findsNothing);
        expect(find.text('七猫完本'), findsOneWidget);
        expect(calls, contains(('qimao', '/v1/home/complete')));

        await tester.pumpWidget(app(const SizedBox()));
        await tester.pumpWidget(app(PluginHomePage(registry: registry)));
        await tester.pumpAndSettle();
        final sourceName = find.text('七猫小说');
        expect(sourceName, findsOneWidget);
        expect(find.text('七猫推荐'), findsNothing);
        expect(find.text('七猫完本'), findsOneWidget);

        final start = tester.getTopLeft(sourceName).dx;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.getTopLeft(sourceName).dx, lessThan(start));
        expect(tester.getSize(sourceButton).width, referenceWidth);

        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getTopLeft(sourceName).dx, closeTo(start, 0.01));
      },
    );
  }
}

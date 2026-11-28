import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/novel_plugins_page.dart';
import 'package:fqapp/services/novel_plugins.dart';

void main() {
  testWidgets(
    'plugin manager only offers ZIP and can remove an installed package',
    (tester) async {
      var installed = true;
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, args, archive) async {
          if (action == 'uninstall') {
            expect(args['sourceId'], 'shuqi');
            installed = false;
            return Uint8List.fromList(utf8.encode('{"value":true}'));
          }
          expect(action, 'list');
          return Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'value': [
                  if (installed)
                    {
                      'sourceId': 'shuqi',
                      'version': '1.0.2',
                      'protocol': 'native-v1',
                    },
                ],
              }),
            ),
          );
        },
      );
      addTearDown(registry.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NovelPluginsPage(registry: registry)),
      );
      await tester.pumpAndSettle();
      expect(find.text('导入或更新插件 ZIP'), findsOneWidget);
      expect(find.textContaining('APK'), findsNothing);
      expect(find.textContaining('JSON'), findsNothing);
      await tester.tap(find.byTooltip('卸载 书旗'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('卸载 书旗'), findsNothing);
    },
  );
}

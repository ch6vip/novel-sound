import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/novel_plugins.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_plugins_test.dart' show frame, metadata;
import 'support/app_ui_host.dart';

void main() {
  for (final style in AppThemeStyle.values) {
    testWidgets('${style.name} search uses only the selected plugin filters', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final requests = <({String? source, Map<String, String> query})>[];
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, args, _) async {
          if (action == 'list') {
            return metadata([
              {
                'sourceId': 'alpha',
                'name': '甲书源',
                'publisher': 'test-alpha',
                'version': '1.0.0',
                'protocol': 'json-v1',
                'searchFilters': [
                  {
                    'id': 'quality',
                    'title': '插件评分',
                    'field': 'score',
                    'options': [
                      {'id': 'high', 'title': '高评分', 'min': 9},
                    ],
                  },
                  {
                    'id': 'period',
                    'title': '录入时间',
                    'options': [
                      {'id': 'recent', 'title': '最近录入'},
                    ],
                  },
                ],
              },
              {
                'sourceId': 'beta',
                'name': '乙书源',
                'publisher': 'test-beta',
                'version': '1.0.0',
                'protocol': 'json-v1',
              },
            ]);
          }
          expect(args['path'], '/v1/search');
          final query = Uri.splitQueryString(args['query']!);
          requests.add((source: args['sourceId'], query: query));
          if (args['sourceId'] == 'beta') {
            return frame({
              'items': [
                {'bookId': '1', 'title': '乙书源结果'},
              ],
            });
          }
          if (query.containsKey('filters')) {
            expect(jsonDecode(query['filters']!), {'period': 'recent'});
            return frame({
              'items': [
                {'bookId': '3', 'title': '近期高分作品', 'score': 9.6},
              ],
            });
          }
          return frame({
            'items': [
              {'bookId': '1', 'title': '普通作品', 'score': 8.2},
              {'bookId': '2', 'title': '高分作品', 'score': 9.4},
            ],
          });
        },
      );
      addTearDown(registry.dispose);
      await tester.pumpWidget(
        AppUiHost(
          store: AppThemeStyleStore()..value = style,
          home: SearchPage(
            initialCategory: SearchCategory.book,
            initialQuery: '测试关键词',
            novelSourceId: 'alpha',
            novelRegistry: registry,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsOneWidget);
      expect(find.text('普通作品'), findsOneWidget);
      expect(find.text('高分作品'), findsOneWidget);
      expect(find.text('状态不限'), findsNothing);
      expect(requests.single.query, {'q': '测试关键词'});

      await tester.tap(find.text('插件评分'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高评分'));
      await tester.pumpAndSettle();
      expect(find.text('普通作品'), findsNothing);
      expect(find.text('高分作品'), findsOneWidget);
      expect(requests, hasLength(1));

      await tester.tap(find.text('录入时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近录入'));
      await tester.pumpAndSettle();
      expect(find.text('近期高分作品'), findsOneWidget);
      expect(requests.last.query.keys, unorderedEquals(['q', 'filters']));

      await tester.tap(find.byKey(const Key('search-plugin-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('乙书源'));
      await tester.pumpAndSettle();
      expect(find.text('乙书源结果'), findsOneWidget);
      expect(find.text('近期高分作品'), findsNothing);
      expect(find.text('插件评分'), findsNothing);
      expect(find.text('最近录入'), findsNothing);
      expect(requests.last.source, 'beta');
      expect(requests.last.query, {'q': '测试关键词'});
    });
  }
}

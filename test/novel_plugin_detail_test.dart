import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_plugins.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

final sampleChapter = Chapter(itemId: '7', title: '插件章节', volumeName: '第一卷');

class FixtureSource extends NovelSource {
  FixtureSource(this.id);
  final String id;

  @override
  Future<MediaItem> book(String bookId) async => MediaItem(
    id: bookId,
    title: '$id 详情',
    author: '$id 作者',
    cover: '',
    badge: '',
    ep: '',
    kind: 'book',
    source: id,
  );
  @override
  Future<List<Chapter>> directory(String bookId) async => [sampleChapter];
  @override
  Future<ChapterContent> chapter(String bookId, Chapter chapter) async =>
      ChapterContent.fromPlainText('这里是插件提供的正文', illustrationsChecked: true);
  @override
  Future<NovelSearchPage> search(String query, {String? cursor}) async =>
      (items: <MediaItem>[], nextCursor: null);
  @override
  void close() {}
}

void main() {
  for (final style in AppThemeStyle.values) {
    for (final id in ['fanqie', 'shuqi', 'example']) {
      testWidgets('${style.name} uses the host layout for $id content', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final source = FixtureSource(id);
        final initial = await source.book('42');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(extensions: [AppStyleTokens.forStyle(style)]),
            home: DetailPage(
              item: initial.copyWith(title: '检索标题'),
              bookSource: source,
              chapterCache: MemoryChapterCache(),
              readerStore: MemoryReaderStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('$id 详情'), findsWidgets);
        expect(find.text('检索标题'), findsNothing);
        expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
        expect(find.byKey(const Key('detail_action_听书')), findsNothing);
        await tester.tap(find.byKey(const Key('detail_read_button')));
        await tester.pumpAndSettle();
        final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
        expect(reader.bookId, id == 'fanqie' ? '42' : 'plugin:$id:42');
        expect(await reader.chapterLoader!(sampleChapter), contains('插件提供的正文'));
      });
    }
  }
}

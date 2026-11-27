import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';

/// 段评楼层下的回复内联预览（对齐官方：不用点开就能看到第一条回复）。
///
/// 截图对照：官方番茄小说在父楼层下直接内联一条回复，什锦铺 1.0.207 只在
/// `replyCount > 0` 时给一个要点的入口，计数为 0 时连入口都没有。
ChapterIdeas _ideas() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      '0': {
        'count': 1,
        'infos': [
          {'comment_id': 'a1'},
        ],
      },
    },
  },
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    required Future<BookCommentPage> Function(ParagraphIdeas, String?) load,
    Future<CommentReplyPage> Function(String commentId)? replyLoader,
    bool autoPreviewReplies = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderIdeasSheet(
            ideas: _ideas(),
            preset: ReaderThemePreset.light,
            loadComments: load,
            replyLoader: replyLoader,
            autoPreviewReplies: autoPreviewReplies,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BookCommentPage oneComment({int replyCount = 0}) => BookCommentPage(
    comments: [
      BookComment(
        id: 'a1',
        text: '只因?',
        userName: '小海山岛的荷儿',
        replyCount: replyCount,
        diggCount: 3,
        createdAt: DateTime(2025, 12, 27),
      ),
    ],
  );

  testWidgets('上游计数为 0 也能把回复内联显示出来', (tester) async {
    var loads = 0;
    await pumpSheet(
      tester,
      load: (_, _) async => oneComment(),
      replyLoader: (_) async {
        loads++;
        return const CommentReplyPage(
          replies: [
            CommentReply(
              id: 'r1',
              text: '小黑子，你够了，我真是没招了。',
              userName: '用户31241257',
            ),
          ],
          totalCount: 1,
        );
      },
    );

    // 不点任何东西，回复就应该已经在楼层下面。
    expect(loads, 1);
    expect(find.textContaining('小黑子', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('用户31241257', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动预览拿到空列表时静默，不出现失败红字', (tester) async {
    var loads = 0;
    await pumpSheet(
      tester,
      load: (_, _) async => oneComment(replyCount: 2),
      replyLoader: (_) async {
        loads++;
        return CommentReplyPage.empty;
      },
    );

    expect(loads, 1);
    // 上游声称有 2 条却回空：自动预览不吭声，计数入口保留（可再点一次）。
    expect(find.text('回复加载失败'), findsNothing);
    expect(find.text('暂无回复'), findsNothing);
    expect(find.text('展开 2 条回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超过预览条数时收在「查看全部」后面', (tester) async {
    await pumpSheet(
      tester,
      load: (_, _) async => oneComment(replyCount: 3),
      replyLoader: (_) async => const CommentReplyPage(
        replies: [
          CommentReply(id: 'r1', text: '第一条回复', userName: '甲'),
          CommentReply(id: 'r2', text: '第二条回复', userName: '乙'),
          CommentReply(id: 'r3', text: '第三条回复', userName: '丙'),
        ],
        totalCount: 3,
      ),
    );

    expect(find.textContaining('第一条回复', findRichText: true), findsOneWidget);
    expect(find.textContaining('第三条回复', findRichText: true), findsNothing);
    expect(find.text('查看全部 3 条回复'), findsOneWidget);

    await tester.tap(find.text('查看全部 3 条回复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第三条回复', findRichText: true), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未开启自动预览时保持按需加载', (tester) async {
    var loads = 0;
    await pumpSheet(
      tester,
      load: (_, _) async => oneComment(replyCount: 2),
      autoPreviewReplies: false,
      replyLoader: (_) async {
        loads++;
        return const CommentReplyPage(
          replies: [
            CommentReply(id: 'r1', text: '按需回复', userName: '甲'),
            CommentReply(id: 'r2', text: '另一条', userName: '乙'),
          ],
          totalCount: 2,
        );
      },
    );

    expect(loads, 0);
    expect(find.text('展开 2 条回复'), findsOneWidget);
    await tester.tap(find.text('展开 2 条回复'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    // 手动展开给全部，不做预览截断。
    expect(find.textContaining('按需回复', findRichText: true), findsOneWidget);
    expect(find.textContaining('另一条', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('回复计数容错', () {
    test('stat 里没有时回落到评论自身的 reply_count', () {
      final page = parseParagraphComments({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': 'a1',
                'reply_count': 3,
                'common': {
                  'content': {'text': '换了个位置放计数'},
                  'user_info': {
                    'base_info': {'user_name': '甲'},
                  },
                },
                'stat': {'digg_count': 3},
              },
            },
          ],
        },
      });
      expect(page.comments.single.replyCount, 3);
    });

    test('同一个键仍然是首选', () {
      final page = parseParagraphComments({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': 'a1',
                'reply_count': 9,
                'common': {
                  'content': {'text': '正文'},
                },
                'stat': {'reply_count': 2},
              },
            },
          ],
        },
      });
      expect(page.comments.single.replyCount, 2);
    });
  });
}

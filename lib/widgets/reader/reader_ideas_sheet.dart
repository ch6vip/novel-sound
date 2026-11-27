import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/chapter_ideas.dart';
import '../../models/comment_reply.dart';
import '../../services/reader_preferences.dart';
import '../comment_emoji.dart';
import '../comment_images.dart';
import '../home/home_design.dart';
import 'reader_theme.dart';

/// Comments for the paragraph whose bubble was tapped.
///
/// Note: the supplied official screenshot defines the sheet layout — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
class ReaderIdeasSheet extends StatefulWidget {
  final ChapterIdeas ideas;

  /// Loads one page of the paragraph's comments. [cursor] is the previous
  /// page's offset, null on the first request.
  final Future<BookCommentPage> Function(
    ParagraphIdeas paragraph,
    String? cursor,
  )
  loadComments;
  final ReaderThemePreset preset;
  final int? initialParaIndex;

  /// Loads a comment's replies on first expand; null disables the affordance.
  ///
  /// Replies are read-only here for the same reason as the detail page: the
  /// backend exposes counts but no reaction writes (issue #95).
  final Future<CommentReplyPage> Function(String commentId)? replyLoader;

  /// 官方段评面板不点开也能在父楼层下看到回复（截图对照 2026-11-26）。
  /// 默认关闭：离线/测试调用方注入数据时不需要为此多发请求。
  final bool autoPreviewReplies;

  const ReaderIdeasSheet({
    super.key,
    required this.ideas,
    required this.loadComments,
    required this.preset,
    this.initialParaIndex,
    this.replyLoader,
    this.autoPreviewReplies = false,
  });

  @override
  State<ReaderIdeasSheet> createState() => _ReaderIdeasSheetState();
}

class _ReaderIdeasSheetState extends State<ReaderIdeasSheet> {
  ParagraphIdeas? _paragraph;
  BookCommentPage? _page;

  /// Lifecycle of the next page: nothing in flight ([_MoreStatus.idle]), the
  /// request is out ([_MoreStatus.fetching]), the result is waiting for the
  /// fling to end ([_MoreStatus.held]), or the last request failed
  /// ([_MoreStatus.failed]).
  _MoreStatus _moreStatus = _MoreStatus.idle;
  BookCommentPage? _heldPage;

  bool _loading = false;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();

  Color get _textColor =>
      widget.preset.isDark ? widget.preset.textColor : const Color(0xFF111111);

  Color get _mutedColor => const Color(0xFF999999);

  bool get _nearEnd => _scroll.hasClients && _scroll.position.extentAfter < 400;

  @override
  void initState() {
    super.initState();
    final paragraphs = widget.ideas.withIdeas;
    if (paragraphs.isEmpty) return;
    _paragraph = paragraphs.firstWhere(
      (paragraph) => paragraph.paraIndex == widget.initialParaIndex,
      orElse: () => paragraphs.first,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Pagination runs on scroll notifications only. The request goes out as soon
  /// as the footer comes into view, hiding the network latency under the
  /// ongoing motion; the append itself waits for the motion to stop — laying
  /// out twenty fresh rows mid-fling shows up as a dropped frame (measured
  /// 28-41ms in the frame-cost test).
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      unawaited(_settleAfterScroll());
    } else if (_moreStatus == _MoreStatus.idle &&
        _page != null &&
        _page!.hasMore &&
        notification.metrics.extentAfter < 400) {
      unawaited(_fetchNextPage());
    }
    return false;
  }

  /// Runs once the motion has stopped: apply a held page, then keep feeding
  /// pages while the reader stays parked near the end of the list.
  Future<void> _settleAfterScroll() async {
    if (!mounted) return;
    if (_moreStatus == _MoreStatus.held) {
      final held = _heldPage!;
      _heldPage = null;
      setState(() {
        _mergePage(held);
        _moreStatus = _MoreStatus.idle;
      });
    }
    // After the first page the list may not be built yet at this point (the
    // spinner shows instead), so the near-end check waits for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_moreStatus == _MoreStatus.idle &&
          _page != null &&
          _page!.hasMore &&
          _nearEnd) {
        unawaited(_fetchNextPage());
      }
    });
  }

  Future<void> _load() async {
    final paragraph = _paragraph;
    if (paragraph == null || _loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.loadComments(paragraph, null);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
      unawaited(_settleAfterScroll());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _fetchNextPage() async {
    final paragraph = _paragraph;
    final page = _page;
    if (paragraph == null || page == null || !page.hasMore) return;
    // failed means the retry button asked for this same page again.
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held ||
        _loading) {
      return;
    }
    setState(() => _moreStatus = _MoreStatus.fetching);
    try {
      final next = await widget.loadComments(paragraph, '${page.nextOffset}');
      if (!mounted) return;
      if (Scrollable.recommendDeferredLoadingForContext(context) && _nearEnd) {
        // Still flinging fast: hold the rows so the append lands in an idle
        // frame. The spinner keeps turning as the "more coming" signal.
        setState(() {
          _heldPage = next;
          _moreStatus = _MoreStatus.held;
        });
        return;
      }
      setState(() {
        _mergePage(next);
        _moreStatus = _MoreStatus.idle;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _moreStatus = _MoreStatus.failed);
    }
  }

  /// Upstream pages never overlap, but a defensive merge keeps the list stable
  /// if the backend ever echoes the last item. Called inside setState.
  void _mergePage(BookCommentPage next) {
    final page = _page!;
    final seen = page.comments.map((c) => c.id).toSet();
    _page = BookCommentPage(
      comments: List.unmodifiable([
        ...page.comments,
        ...next.comments.where((c) => !seen.contains(c.id)),
      ]),
      totalCount: next.totalCount,
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = (_page?.totalCount ?? 0) > 0
        ? _page!.totalCount
        : _paragraph?.count ?? 0;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Text(
                    '$total条评论',
                    key: const Key('reader-ideas-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: IconButton(
                      key: const Key('reader-ideas-close'),
                      tooltip: '收起评论',
                      onPressed: () => Navigator.pop(context),
                      color: _textColor,
                      iconSize: 26,
                      icon: const Icon(LucideIcons.chevron_down),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _commentArea()),
        ],
      ),
    );
  }

  Widget _commentArea() {
    if (_loading) {
      return Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: _mutedColor),
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('评论加载失败', style: TextStyle(color: _mutedColor, fontSize: 13)),
            TextButton(
              onPressed: _load,
              child: Text('重试', style: TextStyle(color: _textColor)),
            ),
          ],
        ),
      );
    }
    final comments = _page?.comments ?? const <BookComment>[];
    if (comments.isEmpty) {
      return Center(
        child: Text(
          _paragraph == null ? '本章还没有段评' : '暂无评论',
          style: TextStyle(color: _mutedColor, fontSize: 13),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        key: const Key('reader-ideas-comments'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        // One extra footer slot while more pages exist or the last fetch failed.
        itemCount:
            comments.length +
            ((_page!.hasMore || _moreStatus == _MoreStatus.failed) ? 1 : 0),
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          if (index >= comments.length) {
            return _moreFooter();
          }
          return _CommentRow(
            comment: comments[index],
            textColor: _textColor,
            mutedColor: _mutedColor,
            replyLoader: widget.replyLoader,
            autoPreviewReplies: widget.autoPreviewReplies,
          );
        },
      ),
    );
  }

  /// Bottom slot: a thin spinner while the next page loads, a retry label when
  /// it failed, nothing when the paragraph is exhausted.
  Widget _moreFooter() {
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _mutedColor,
            ),
          ),
        ),
      );
    }
    if (_moreStatus == _MoreStatus.failed) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(_fetchNextPage()),
          child: Text('加载失败，点击重试', style: TextStyle(color: _textColor)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Lifecycle of the next page request; see [_onScrollNotification].
enum _MoreStatus { idle, fetching, held, failed }

/// Avatar beside the name and body; date, reply and reactions below the body.
///
/// Tapping the reply counter expands that comment's replies in place. They load
/// on first tap only: a paragraph can carry many comments and most are never
/// expanded (issue #95).
class _CommentRow extends StatefulWidget {
  final BookComment comment;
  final Color textColor;
  final Color mutedColor;
  final Future<CommentReplyPage> Function(String commentId)? replyLoader;
  final bool autoPreviewReplies;

  const _CommentRow({
    required this.comment,
    required this.textColor,
    required this.mutedColor,
    this.replyLoader,
    this.autoPreviewReplies = false,
  });

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  CommentReplyPage? _replies;
  bool _loading = false;
  bool _failed = false;

  /// 上游明确回了「没有回复」（code=0 但 reply_list 为空）。这跟请求失败不是
  /// 一回事：段评的 reply_count 常常大于 0，实际上游早把这批回复清掉了。
  bool _empty = false;

  /// 用户点过「展开」：回复全部展开，不再是预览态。
  bool _expanded = false;

  /// 自动预览只发一次，失败也不反复重试（手动点开仍可重试）。
  bool _previewStarted = false;

  /// 预览上限：官方在楼层下先露两条，余下走「查看全部」。
  static const int _previewLimit = 2;

  BookComment get comment => widget.comment;
  Color get textColor => widget.textColor;
  Color get mutedColor => widget.mutedColor;

  /// Zero-reply comments get no collapsible footer (issue #173); the official
  /// list only appends one when replies remain.
  ///
  /// 预览到回复而上游计数为 0 时也算有回复，否则预览出来的回复会在重排后连同
  /// 入口一起消失。
  bool get _hasReplies => _replies != null || comment.replyCount > 0;

  /// 预览里还有没露出来的回复。
  bool get _hasHiddenReplies =>
      widget.autoPreviewReplies &&
      !_expanded &&
      (_replies?.replies.length ?? 0) > _previewLimit;

  @override
  void initState() {
    super.initState();
    _schedulePreview();
  }

  @override
  void didUpdateWidget(_CommentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ListView.builder 没有 key 时按位置复用 State：换了一条评论就得清干净，
    // 否则上一条的回复会挂到这一条下面。
    if (oldWidget.comment.id != widget.comment.id) {
      _replies = null;
      _failed = false;
      _empty = false;
      _loading = false;
      _expanded = false;
      _previewStarted = false;
      _schedulePreview();
    }
  }

  /// 首帧之后再拉预览，避免 build 期间发请求。
  void _schedulePreview() {
    if (!widget.autoPreviewReplies || widget.replyLoader == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _previewStarted) return;
      _previewStarted = true;
      unawaited(_loadReplies(manual: false));
    });
  }

  /// 预览态只渲染前 [_previewLimit] 条。
  CommentReplyPage _previewPage(CommentReplyPage page) {
    if (!widget.autoPreviewReplies ||
        _expanded ||
        page.replies.length <= _previewLimit) {
      return page;
    }
    return CommentReplyPage(
      replies: List.unmodifiable(page.replies.take(_previewLimit)),
      totalCount: page.totalCount,
      hasMore: page.hasMore,
      cursor: page.cursor,
    );
  }

  Future<void> _toggleReplies() async {
    if (_loading) return;
    // 有回复时：先把折叠的预览全展开，已全展开则收起；还没有回复才去拉。
    if (_replies != null) {
      setState(() {
        if (_hasHiddenReplies) {
          _expanded = true;
        } else {
          _replies = null;
          _expanded = false;
        }
      });
      return;
    }
    await _loadReplies(manual: true);
  }

  Future<void> _loadReplies({required bool manual}) async {
    if (_loading) return;
    final loader = widget.replyLoader;
    if (loader == null) return;
    var leased = false;
    if (!manual) {
      await _ReplyPreviewGate.acquire();
      leased = true;
    }
    if (!mounted) {
      if (leased) _ReplyPreviewGate.release();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _empty = false;
    });
    try {
      final page = await loader(comment.id);
      if (!mounted) return;
      setState(() {
        // 上游在错误的 comment_source 命名空间里会照常回 200，但 reply_list 为空、
        // total 为 0（参见 #491）。这种「声称有回复却一条都拿不到」的响应不能渲染成
        // 空白或「暂无回复」，否则看起来就是评论区展开后什么都没显示；保留原计数
        // 并按失败处理，给出可重试的入口——与书评详情面板同一套语义（#492）。
        if (page.isEmpty) {
          // 已经拿到过回复时不要被一次空响应清空：上游偶发返回空列表，
          // 重试或翻页后不该让用户已经看到的内容凭空消失，所以这里不动 _replies。
          //
          // 空列表 = 上游明确说这条段评没有回复（code=0、reply_list 空）。段评的
          // reply_count 与上游真实回复数经常不一致，把它当失败只会让入口变成
          // 「回复加载失败，点击重试」死循环；真正的失败只来自下面的 catch。
          // 自动预览拿到空也不打扰阅读，不一直挂着「加载中」。
          _empty = true;
          _failed = false;
        } else {
          _replies = page;
          _failed = false;
          _expanded = _expanded || manual;
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = manual;
        _loading = false;
      });
    } finally {
      if (leased) _ReplyPreviewGate.release();
    }
  }

  /// Reply counter: tap to expand, chevron rotates with the state.
  ///
  /// The three labels follow the official state machine
  /// (`xt1/e0.java` `A2()`, driven by the holder's state):
  ///
  /// | 状态 | 文案 | 箭头 |
  /// | --- | --- | --- |
  /// | 可展开 | `展开%d条回复` (strings `b9g`) | 0° |
  /// | 已展开 | `收起` (strings `b9i`) | 180° |
  /// | 加载中 | `加载中` (strings `b9j`) | — |
  ///
  /// Without a loader it stays a plain count, exactly as before: an offline
  /// caller must not get a control that can only fail.
  Widget _replyCounter(TextStyle metaStyle) {
    final canOpen = widget.replyLoader != null;
    final loaded = _replies;
    final open = loaded != null;
    // 预览到的条数优先：上游的 reply_count 经常是 0，而回复其实拿得到。
    final loadedTotal = loaded == null
        ? 0
        : (loaded.totalCount > 0 ? loaded.totalCount : loaded.replies.length);
    final label = comment.replyCount > 0 ? comment.replyCount : loadedTotal;
    final labelText = formatCount(label);
    final totalText = formatCount(loadedTotal);
    // 不可展开时保留原来的只读计数，不冒充「展开 N 条回复」。
    if (!canOpen) {
      return Text(label > 0 ? '回复 $labelText' : '回复', style: metaStyle);
    }
    final String text;
    if (_loading && !open) {
      text = '加载中';
    } else if (!open && _empty) {
      // 上游确实没有回复：直说，而不是让用户反复点「展开 N 条回复」。
      text = '暂无回复';
    } else if (!open) {
      text = '展开 $labelText 条回复';
    } else if (_hasHiddenReplies) {
      text = '查看全部 $totalText 条回复';
    } else {
      text = '收起';
    }
    // 「暂无回复」是终态：不挂点击、不画箭头，避免用户反复点一个只会再空一次的入口。
    final inert = !open && _empty;
    return GestureDetector(
      key: ValueKey('reader_reply_toggle_${comment.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: inert ? null : () => unawaited(_toggleReplies()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: metaStyle),
          if (!inert) ...[
            const SizedBox(width: 2),
            // 官方是把同一个箭头旋转 0°/180°，这里用上下箭头等价表达。
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(
                LucideIcons.chevron_down,
                size: 13,
                color: mutedColor,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final time = comment.paragraphTime();
    final metaStyle = TextStyle(color: mutedColor, fontSize: 12.5, height: 1.3);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IdeaAvatar(
            url: comment.userAvatar,
            size: 32,
            mutedColor: mutedColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.userName.isEmpty ? '读者' : comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                    ),
                    if (comment.isAuthor) ...[
                      const SizedBox(width: 5),
                      const Text(
                        '作者',
                        style: TextStyle(
                          color: HomePalette.accent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (comment.text.isNotEmpty)
                  CommentEmojiText(
                    text: comment.text,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      height: 1.5,
                    ),
                  ),
                if (comment.imageUrls.isNotEmpty) ...[
                  if (comment.text.isNotEmpty) const SizedBox(height: 8),
                  CommentImages(imageUrls: comment.imageUrls),
                ],
                if (_replies case final CommentReplyPage loaded) ...[
                  const SizedBox(height: 8),
                  _ReplyList(
                    page: _previewPage(loaded),
                    textColor: textColor,
                    mutedColor: mutedColor,
                  ),
                ],
                if (_failed) ...[
                  const SizedBox(height: 2),
                  // 失败文案本身就是重试入口：官方在这里是静默的，但用户
                  // 点开过就应该能再试一次，而不是被一句「失败」卡住。
                  TextButton(
                    key: ValueKey('reader_reply_error_${comment.id}'),
                    onPressed: _loading
                        ? null
                        : () => _loadReplies(manual: true),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      '回复加载失败，点击重试',
                      style: TextStyle(color: mutedColor, fontSize: 12.5),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (time.isNotEmpty) Text(time, style: metaStyle),
                          if (_hasReplies) _replyCounter(metaStyle),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // The backend exposes counts but no reaction writes. Keep
                    // these as read-only indicators, without fake tap handlers.
                    Semantics(
                      label: '${comment.diggCount}人点赞',
                      excludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.heart, size: 20, color: mutedColor),
                          const SizedBox(width: 5),
                          Text(
                            comment.diggCount > 0
                                ? formatCount(comment.diggCount)
                                : '点赞',
                            style: metaStyle,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Icon(
                      LucideIcons.heart_crack,
                      size: 20,
                      color: mutedColor,
                      semanticLabel: '不喜欢',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only reply list under an expanded paragraph comment.
class _ReplyList extends StatelessWidget {
  final CommentReplyPage page;
  final Color textColor;
  final Color mutedColor;

  const _ReplyList({
    required this.page,
    required this.textColor,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    if (page.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: mutedColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final reply in page.replies)
            _ReplyTile(
              reply: reply,
              textColor: textColor,
              mutedColor: mutedColor,
            ),
          if (page.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '仅显示部分回复',
                style: TextStyle(color: mutedColor, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  final CommentReply reply;
  final Color textColor;
  final Color mutedColor;

  const _ReplyTile({
    required this.reply,
    required this.textColor,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final time = reply.relativeTime();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IdeaAvatar(
            key: ValueKey('reader_reply_avatar_${reply.id}'),
            url: reply.userAvatar,
            size: 22,
            mutedColor: mutedColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(
                        text: reply.userName.isEmpty ? '读者' : reply.userName,
                        style: TextStyle(
                          color: mutedColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (time.isNotEmpty)
                        TextSpan(
                          text: '  $time',
                          style: TextStyle(color: mutedColor, fontSize: 11.5),
                        ),
                      // Image-only replies would otherwise leave a blank line.
                      if (reply.text.isNotEmpty)
                        ...commentEmojiSpans('\n${reply.text}', fontSize: 13.5),
                    ],
                  ),
                ),
                if (reply.imageUrls.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  CommentImages(imageUrls: reply.imageUrls),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Round avatar shared by paragraph comments and their replies.
class _IdeaAvatar extends StatelessWidget {
  final String url;
  final double size;
  final Color mutedColor;

  const _IdeaAvatar({
    super.key,
    required this.url,
    required this.size,
    required this.mutedColor,
  });

  Widget _fallback() => ColoredBox(
    color: mutedColor.withValues(alpha: 0.12),
    child: Icon(LucideIcons.user, size: size * 0.56, color: mutedColor),
  );

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox.square(
      dimension: size,
      child: url.isEmpty
          ? _fallback()
          : Image.network(
              url,
              fit: BoxFit.cover,
              // The upstream serves 144px avatars for small slots; decode once
              // at the display size instead of keeping full-size surfaces
              // alive for every row.
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              frameBuilder: (context, child, frame, _) =>
                  frame == null ? _fallback() : child,
              errorBuilder: (context, _, _) => _fallback(),
            ),
    ),
  );
}

/// 段评预览的并发闸门：一屏能挂二十条评论，全部同时摘要会打爆上游。
/// 只在自动预览（用户没点开）时占用，手动点开不加限。
class _ReplyPreviewGate {
  static const int _maxConcurrent = 3;
  static int _active = 0;
  static final List<Completer<void>> _waiting = <Completer<void>>[];

  static Future<void> acquire() {
    if (_active < _maxConcurrent) {
      _active += 1;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  static void release() {
    if (_waiting.isEmpty) {
      _active -= 1;
      return;
    }
    _waiting.removeAt(0).complete();
  }
}

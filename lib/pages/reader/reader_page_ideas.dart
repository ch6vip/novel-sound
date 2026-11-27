part of '../reader_page.dart';

/// 上一次成功拿到回复的命名空间组合下标（见 [_ReaderPageIdeas] 的回复加载器）。
/// 段评与书评的回复落在不同的 (source, type, group[, channel]) 空间里，同一本书
/// 里也可能混着两种；记住成功的那个组合，后续命中一次请求就够了。
int? _replyCombo;

/// Paragraph ideas (段评) loading and the ideas sheet.
extension _ReaderPageIdeas on _ReaderPageState {
  /// Loads the chapter's paragraph ideas. Decoration only: a failure leaves the
  /// reader fully usable with the段评 action hidden.
  Future<void> _loadIdeas(Chapter chapter, int generation) async {
    if (widget.localOnly) return;
    final loader = widget.ideasLoader;
    if (loader == null && widget.chapterCache != null) {
      // An injected cache means the caller drives its own data; do not reach
      // for the network behind its back.
      return;
    }
    try {
      final ideas = await (loader ?? _defaultIdeas)(chapter.itemId);
      if (!mounted || generation != _loadGeneration) return;
      if (chapter.itemId != widget.chapters[_index].itemId) return;
      final cacheKey = '${widget.bookId}\u0000${chapter.itemId}';
      final previous = _ideasCache[cacheKey];
      _ideasCache[cacheKey] = (version: chapter.version, ideas: ideas);
      while (_ideasCache.length > 12) {
        _ideasCache.remove(_ideasCache.keys.first);
      }
      final unchanged =
          previous?.version == chapter.version &&
          _sameChapterIdeas(previous!.ideas, ideas);
      if (unchanged) return;
      _setState(() {
        _ideas = ideas;
        ++_ideasRevision;
      });
      // Note: Old image-aware caches can still lack paragraph ids. Refresh
      // only when ideas need them; never fabricate ids from display order.
      // .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
      if (!_chapterContent.paragraphIdsChecked &&
          ideas.paragraphs.any((paragraph) => paragraph.showsBubble)) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (_) {
      // Keep the section hidden rather than surfacing a failure. Catches Error
      // as well as Exception: ideas are decoration, not a page-level failure.
    }
  }

  /// The in-text paragraph-comment bubble, built during layout so it can be
  /// measured as a placeholder at the end of the paragraph.
  ///
  /// Note: 气泡的门槛与几何规格取自官方客户端 — 见
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Widget _buildParagraphBubble(
    int paraIndex,
    int count,
    ParagraphBubbleVariant variant, {
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
  }) => ReaderParagraphBubble(
    count: count,
    metrics: ReaderBubbleMetrics.forFontSize(
      MediaQuery.textScalerOf(context).scale(_preferences.fontSize),
      variant: variant,
    ),
    preset: _effectivePreset,
    onTap: () => unawaited(
      _showIdeas(
        focusParaIndex: paraIndex,
        sourceChapter: sourceChapter,
        sourceIdeas: sourceIdeas,
      ),
    ),
  );

  Future<void> _showIdeas({
    int? focusParaIndex,
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
  }) async {
    final ideaSnapshot = sourceIdeas ?? _ideas;
    if (ideaSnapshot.isEmpty) return;
    _setControlsVisible(false);
    final chapter = sourceChapter ?? widget.chapters[_index];
    // Keep immersive on while the sheet is open (#57): the sheet pushes a
    // route, which would otherwise release the system bars. The flag is
    // read by [_syncSystemBars] when the route change lands.
    _ideasSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: _effectivePreset.isDark
            ? _effectivePreset.panelColor
            : Colors.white,
        // E-ink (#57): a dimmed scrim forces a full-screen gray wash and
        // ghosts on e-ink. Transparent keeps the page readable behind the
        // sheet; tapping outside still dismisses it.
        barrierColor: einkModeNotifier.value
            ? Colors.transparent
            : Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (context) => FractionallySizedBox(
          // Match the supplied official screenshot, keeping the paragraph visible
          // above the comments. Note: 2026-09-11-reader-paragraph-bubble.md.
          heightFactor: 0.69,
          child: ReaderIdeasSheet(
            ideas: ideaSnapshot,
            preset: _effectivePreset,
            // Each bubble opens only that paragraph's comments.
            initialParaIndex: focusParaIndex,
            loadComments: (paragraph, cursor) async {
              final resolver = widget.commentResolver;
              if (resolver != null) {
                return resolver(chapter.itemId, paragraph, cursor);
              }
              return _defaultComments(
                chapter,
                paragraph,
                ideaSnapshot.itemVersion,
                cursor,
              );
            },
            // 回复按需展开（issue #95）。与段评正文同一套「注入即离线」
            // 约定：调用方自己提供数据时不接网络，也就不给可点的回复入口。
            replyLoader: _ideasReplyLoader(chapter),
            // 官方段评面板不用点开就能看到楼层下的回复；这里开启自动预览。
            autoPreviewReplies: true,
          ),
        ),
      );
    } finally {
      // The sheet is gone. Release the immersive hold here only if this
      // route is already current again; otherwise didChangeDependencies
      // releases it once the route regains current status (#57). The
      // sheet route stays present until its close animation ends, so an
      // unconditional release here would sync "not immersive" before
      // that notification lands and flash the status bar for a frame.
      // Guard mounted: if the reader was disposed while the sheet was
      // open, dispose already closed the device session and no stale
      // call may follow it.
      if (mounted && _routeCurrent) {
        _ideasSheetOpen = false;
        _syncSystemBars();
      }
      // 墨水屏：段评面板关闭后刷一次，清掉面板残影。
      _maybeEinkRefresh();
    }
  }

  /// Default idea fetch and comment resolution; see [ReaderPage.ideasLoader].
  Future<ChapterIdeas> _defaultIdeas(String itemId) =>
      ApiClient.instance.chapterIdeas(itemId);

  /// Loads one paragraph's comments.
  ///
  /// Note: the upstream wants `server_channel=38` here, not the 43 the official
  /// presenter assigns, and it needs the chapter version — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Future<BookCommentPage> _defaultComments(
    Chapter chapter,
    ParagraphIdeas paragraph,
    String ideaVersion,
    String? cursor,
  ) async {
    final version = chapter.version.isNotEmpty ? chapter.version : ideaVersion;
    return ApiClient.instance.paragraphComments(
      widget.bookId,
      chapter.itemId,
      itemVersion: version,
      paraIndex: paragraph.paraIndex,
      cursor: cursor,
    );
  }

  /// Loads one comment's replies for the paragraph sheet.
  ///
  /// Null when the caller injected its own comment data or when a chapter
  /// cache was injected (both mark an offline caller), which keeps the reply
  /// counter a plain read-only number for them.
  Future<CommentReplyPage> Function(String commentId)? _ideasReplyLoader(
    Chapter chapter,
  ) {
    if (widget.commentResolver != null ||
        widget.ideasLoader != null ||
        widget.chapterCache != null) {
      return null;
    }
    if (widget.bookId.isEmpty) return null;
    final book = widget.bookId;
    final itemId = chapter.itemId;
    return (commentId) async {
      // 上游按 (comment_source, comment_type, group_type[, server_channel])
      // 四元组切分评论数据空间：段评列表 (2, 1, 15, 38)、书评列表 (1, 2, 1, 7)，
      // 回复接口沿用同一套标识。传错不报错，只回 200 + 空 reply_list，界面上就是
      // 「展开 3 条回复」点开一片空白。
      //
      // 2026-11-27 在设备上逐组实测：段评回复是 (503, 1, 1, 38)、书评回复是
      // (501, 2, 1, 7)，决定性字段是 comment_type —— 同一 comment_id 用
      // 503 + type 2 只拿到空列表，换成 503 + type 1 才有数据。第一组是段评命名
      // 空间，第二组兜底（个别书的段评回复确实落在 501 空间）。拿到非空结果立刻
      // 返回并记住组合，同一本书下次只发一个请求；全为空时返回条数最多的一页，
      // 由上层区分「暂无回复」与「加载失败」。
      final version = chapter.version;
      final attempts = <Future<CommentReplyPage> Function()>[
        () => ApiClient.instance.commentReplies(
          book,
          commentId,
          groupId: itemId,
          commentSource: 503,
          commentType: 1,
          groupType: 1,
          serverChannel: 38,
          itemId: itemId,
          itemVersion: version,
        ),
        () => ApiClient.instance.commentReplies(
          book,
          commentId,
          groupId: book,
          commentSource: 501,
          commentType: 2,
          groupType: 1,
        ),
      ];
      CommentReplyPage? best;
      // 先试上次成功的组合，再按顺序补齐其余组合。
      final preferred = _replyCombo;
      final order = <int>[
        if (preferred != null && preferred < attempts.length) preferred,
        for (var i = 0; i < attempts.length; i++)
          if (i != preferred) i,
      ];
      for (final i in order) {
        try {
          final page = await attempts[i]();
          if (page.replies.isNotEmpty) {
            _replyCombo = i;
            return page;
          }
          if (best == null || page.replies.length > best.replies.length) {
            best = page;
          }
        } on Exception {
          continue;
        }
      }
      return best ?? CommentReplyPage.empty;
    };
  }
}

/// Full data comparison, not just bubble counts. The same number of comments
/// can move to a different paragraph (or change ids/content) while the bubble
/// decoration stays identical; that still has to refresh the sheet data.
bool _sameChapterIdeas(ChapterIdeas a, ChapterIdeas b) {
  if (identical(a, b)) return true;
  if (a.itemVersion != b.itemVersion ||
      a.paragraphs.length != b.paragraphs.length) {
    return false;
  }
  for (var i = 0; i < a.paragraphs.length; i++) {
    final left = a.paragraphs[i];
    final right = b.paragraphs[i];
    if (left.paraIndex != right.paraIndex ||
        left.count != right.count ||
        left.userCount != right.userCount ||
        left.isAuthor != right.isAuthor ||
        !listEquals(left.commentIds, right.commentIds) ||
        !mapEquals(left.channelCounts, right.channelCounts)) {
      return false;
    }
  }
  return true;
}

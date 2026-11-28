part of 'novel_plugins.dart';

enum NovelCapability {
  home,
  categories,
  rankings,
  searchCue,
  searchSuggestions,
  hotSearch,
  bookReviews,
  commentReplies,
  chapterReviews,
  author,
  relatedWorks,
  audio,
  audioTimeline,
  adaptation,
  accountImport,
}

class NovelHomeChannel {
  const NovelHomeChannel(this.id, this.title, {this.kind = 'book'});

  final String id;
  final String title;
  final String kind;
}

class NovelSearchFilter {
  const NovelSearchFilter(this.id, this.title, this.field, this.options);

  final String id;
  final String title;

  /// Null means the plugin applies the selected option on its search endpoint.
  final String? field;
  final List<NovelSearchFilterOption> options;

  bool matches(MediaItem item, NovelSearchFilterOption option) {
    final value = switch (field) {
      'score' => item.score,
      'creationStatus' => item.creationStatus < 0 ? null : item.creationStatus,
      'wordNumber' => item.wordNumber > 0 ? item.wordNumber : null,
      _ => null,
    };
    return value != null &&
        (option.min == null || value >= option.min!) &&
        (option.max == null || value < option.max!);
  }
}

class NovelSearchFilterOption {
  const NovelSearchFilterOption(this.id, this.title, this.min, this.max);

  final String id;
  final String title;
  final num? min;
  final num? max;
}

List<NovelSearchFilter> _readSearchFilters(
  Object? raw, {
  required bool native,
}) {
  if (raw is! List) return const [];
  final filters = <NovelSearchFilter>[];
  final ids = <String>{};
  for (final row in raw.take(8)) {
    if (row is! Map) continue;
    final id = _text(row['id']);
    final title = _text(row['title']).trim();
    final field = row['field'];
    final options = row['options'];
    if (!ShelfIdentity.isValidContentId(id) ||
        id.length > 32 ||
        title.isEmpty ||
        title.length > 32 ||
        (field == null
            ? native
            : !const {
                'score',
                'creationStatus',
                'wordNumber',
              }.contains(field)) ||
        options is! List ||
        !ids.add(id)) {
      continue;
    }
    final parsed = <NovelSearchFilterOption>[];
    final optionIds = <String>{};
    for (final option in options.take(24)) {
      if (option is! Map) continue;
      final optionId = _text(option['id']);
      final label = _text(option['title']).trim();
      final lower = option['min'];
      final upper = option['max'];
      if (!ShelfIdentity.isValidContentId(optionId) ||
          optionId.length > 32 ||
          label.isEmpty ||
          label.length > 32 ||
          (lower != null && (lower is! num || !lower.isFinite)) ||
          (upper != null && (upper is! num || !upper.isFinite)) ||
          (field != null && lower == null && upper == null) ||
          (lower is num && upper is num && lower >= upper) ||
          !optionIds.add(optionId)) {
        continue;
      }
      parsed.add(
        NovelSearchFilterOption(optionId, label, lower as num?, upper as num?),
      );
    }
    if (parsed.isNotEmpty) {
      filters.add(
        NovelSearchFilter(
          id,
          title,
          field as String?,
          List.unmodifiable(parsed),
        ),
      );
    }
  }
  return List.unmodifiable(filters);
}

typedef NovelHomePage = ({
  List<MediaItem> items,
  List<HomeCell> cells,
  String? nextCursor,
});

const _legacyChannels = [
  NovelHomeChannel('recommended', '推荐'),
  NovelHomeChannel('novels', '小说'),
];

Set<NovelCapability> _readCapabilities(Object? raw) => {
  if (raw is Map)
    for (final capability in NovelCapability.values)
      if (raw[capability.name] == 1) capability,
};

List<NovelHomeChannel> _readChannels(Object? raw) {
  if (raw is! List) return const [];
  final channels = <NovelHomeChannel>[];
  final ids = <String>{};
  for (final entry in raw.take(32)) {
    if (entry is! Map) continue;
    final id = _text(entry['id']);
    final title = _text(entry['title']).trim();
    final kind = _text(entry['kind']);
    if (!ShelfIdentity.isValidContentId(id) ||
        title.isEmpty ||
        title.length > 32 ||
        !ids.add(id)) {
      continue;
    }
    channels.add(
      NovelHomeChannel(id, title, kind: kind.isEmpty ? 'book' : kind),
    );
  }
  return List.unmodifiable(channels);
}

class NovelSourceCapabilities {
  const NovelSourceCapabilities()
    : _plugin = null,
      _legacy = null,
      _json = null;

  const NovelSourceCapabilities._(this._plugin, {this._legacy, this._json});

  final NovelPlugin? _plugin;
  final _NativeNovelSource? _legacy;
  final _JsonNovelSource? _json;

  Future<NovelSearchPage> search(
    String query, {
    String? cursor,
    required Map<String, String> selections,
  }) {
    if (_legacy case final legacy?) return legacy.search(query, cursor: cursor);
    final filters = {
      for (final filter in _plugin!.searchFilters)
        if (filter.field == null)
          for (final option in filter.options)
            if (selections[filter.id] == option.id) filter.id: option.id,
    };
    return _json!._searchWithFilters(query, cursor: cursor, filters: filters);
  }

  bool supports(NovelCapability capability) =>
      _plugin?.capabilities.contains(capability) == true ||
      switch (capability) {
        NovelCapability.home => _plugin?.hasBookstoreFeed == true,
        NovelCapability.categories ||
        NovelCapability.rankings ||
        NovelCapability.searchCue ||
        NovelCapability.searchSuggestions ||
        NovelCapability.hotSearch ||
        NovelCapability.bookReviews ||
        NovelCapability.commentReplies ||
        NovelCapability.chapterReviews ||
        NovelCapability.author ||
        NovelCapability.relatedWorks ||
        NovelCapability.audio ||
        NovelCapability.audioTimeline ||
        NovelCapability.adaptation => _plugin?.hasFullFanqieExperience == true,
        NovelCapability.accountImport => false,
      };

  String _allowedMediaUrl(Object? value) {
    final url = _mediaUrl(value);
    if (url.isEmpty) return '';
    final uri = Uri.parse(url);
    final host = uri.host.toLowerCase();
    return uri.port == 443 &&
            _plugin?.httpsHosts.contains(host) == true &&
            host.contains('.') &&
            !host.endsWith('.local') &&
            !host.endsWith('.localhost') &&
            InternetAddress.tryParse(host) == null
        ? url
        : '';
  }

  bool _declares(NovelCapability capability) =>
      _plugin?.capabilities.contains(capability) == true;

  List<NovelHomeChannel> get channels => _declares(NovelCapability.home)
      ? _plugin!.channels
      : _plugin?.hasBookstoreFeed == true
      ? _legacyChannels
      : const [];

  ApiClient? get storyFeedApi =>
      channels.any(
        (channel) => channel.id == 'stories' && channel.kind == 'ugc',
      )
      ? _legacy?._api
      : null;

  Future<NovelHomePage> home(String channel, {String? cursor}) async {
    if (!channels.any((entry) => entry.id == channel)) {
      throw const FormatException('此书源没有该栏目');
    }
    if (_declares(NovelCapability.home) && _legacy == null) {
      final result = await _json!._get(['home', channel], {'cursor': ?cursor});
      final items = [
        for (final raw in _list(result['items'])) ?_homeItem(_object(raw)),
      ];
      return (
        items: items,
        cells: const <HomeCell>[],
        nextCursor: _cursor(result['nextCursor']),
      );
    }
    final state = cursor == null ? null : _object(jsonDecode(cursor));
    final page = await _legacy!.channelPage(
      channel,
      offset: state?['offset'] as int? ?? 0,
      sessionId: state?['session'] as String?,
    );
    return (
      items: page.items,
      cells: page.cells,
      nextCursor: page.nextOffset == null
          ? null
          : jsonEncode({'offset': page.nextOffset, 'session': page.sessionId}),
    );
  }

  MediaItem? _homeItem(Map<String, dynamic> value) {
    final kind = _text(value['kind']);
    if (kind.isEmpty || kind == 'book') {
      return _json!
          ._item(value)
          .copyWith(cover: _allowedMediaUrl(value['coverUrl']));
    }
    if (_plugin?.id != 'fanqie' ||
        !const {'video', 'manju', 'manga', 'audio', 'ugc'}.contains(kind)) {
      return null;
    }
    return MediaItem(
      id: _id(value['id']),
      title: _requiredText(value['title']),
      cover: _allowedMediaUrl(value['coverUrl']),
      author: _text(value['author']),
      badge: _text(value['badge']),
      ep: _text(value['episodes']),
      kind: kind,
      seriesId: value['seriesId'] == null ? null : _id(value['seriesId']),
      episodeId: value['episodeId'] == null ? null : _id(value['episodeId']),
      intro: _text(value['intro']),
      source: _plugin!.id,
    );
  }

  Future<SearchCue> searchCue() async {
    if (!_declares(NovelCapability.searchCue)) return _legacy!._api.searchCue();
    final payload = await _json!._get(['search', 'cue']);
    final words = _list(payload['words']).whereType<String>().toList();
    return SearchCue(words: words);
  }

  Future<CategoryFront> categories({int tab = 1}) async {
    if (!_declares(NovelCapability.categories)) {
      return _legacy!._api.categoryFront(tab: tab);
    }
    final data = await _json!._get(['categories'], {'tab': '$tab'});
    return CategoryFront(
      tabs: [
        for (final row in _entries(data['tabs'])) ?CategoryTab.fromRaw(row),
      ],
      dims: [
        for (final row in _entries(data['dims'])) ?CategoryDim.fromRaw(row),
      ],
      tiles: [
        for (final row in _entries(data['tiles']))
          CategoryTile(
            name: _requiredText(row['name']),
            dim: _text(row['dim']),
            id: _text(row['id']),
            hot: row['hot'] == true,
          ),
      ],
    );
  }

  Future<RankCatalog> rankCatalog() async {
    if (!_declares(NovelCapability.rankings)) {
      return _legacy!._api.rankCatalog();
    }
    return RankCatalog.fromJson(await _json!._get(['rankings'])) ??
        RankCatalog.empty;
  }

  Future<RankBoard> rankBoard({
    required String rankId,
    required int algo,
    int categoryId = 0,
    int offset = 0,
    int startAt = 1,
  }) async {
    if (!_declares(NovelCapability.rankings)) {
      return _legacy!._api.rankBoard(
        rankId: rankId,
        algo: algo,
        categoryId: categoryId,
        offset: offset,
        startAt: startAt,
      );
    }
    return RankBoard.fromJson(
      await _json!._get(
        ['rankings', _id(rankId)],
        {'algo': '$algo', 'categoryId': '$categoryId', 'offset': '$offset'},
      ),
    );
  }

  Future<List<SearchSuggestion>> searchSuggestions(String query) async {
    if (!_declares(NovelCapability.searchSuggestions)) {
      return _legacy!._api.searchSuggestions(query);
    }
    final data = await _json!._get(['search', 'suggestions'], {'q': query});
    return [
      for (final row in _entries(data['items']))
        SearchSuggestion(text: _requiredText(row['text'])),
    ];
  }

  Future<HotSearch> hotSearch() async {
    if (!_declares(NovelCapability.hotSearch)) return _legacy!._api.hotSearch();
    final data = await _json!._get(['search', 'hot']);
    return HotSearch(
      entries: [
        for (final row in _entries(data['items']))
          HotSearchEntry(
            title: _requiredText(row['title']),
            hotValue: _text(row['hotValue']),
            badge: _text(row['badge']),
          ),
      ],
    );
  }

  Future<AuthorProfile> author(String authorId) async {
    if (!_declares(NovelCapability.author)) {
      return _legacy!._api.authorProfile(authorId);
    }
    final data = await _json!._get(['authors', _id(authorId)]);
    return AuthorProfile(
      id: authorId,
      name: _requiredText(data['name']),
      avatar: _allowedMediaUrl(data['avatarUrl']),
      description: _text(data['description']),
      level: _text(data['level']),
      followerCount: _integer(data['followerCount']),
      workCount: _integer(data['workCount']),
      works: [
        for (final row in _entries(data['works']))
          AuthorWork(
            id: _id(row['bookId']),
            title: _requiredText(row['title']),
            cover: _allowedMediaUrl(row['coverUrl']),
            abstract: _text(row['intro']),
            category: _text(row['category']),
            creationStatus: _integer(row['creationStatus'], fallback: -1),
            wordNumber: _integer(row['wordNumber']),
            readCount: _text(row['readCount']),
          ),
      ],
    );
  }

  Future<List<RelatedWork>> relatedWorks(String bookId) async {
    if (!_declares(NovelCapability.relatedWorks)) {
      return _legacy!._api.relatedWorks(bookId);
    }
    final data = await _json!._get(['books', _id(bookId), 'related']);
    return [
      for (final row in _entries(data['items']))
        if (row['kind'] == 'book' ||
            (row['kind'] == 'video' && _plugin?.id == 'fanqie'))
          RelatedWork(
            kind: _text(row['kind']),
            id: _id(row['id']),
            title: _requiredText(row['title']),
            cover: _allowedMediaUrl(row['coverUrl']),
            label: _text(row['label']),
          ),
    ];
  }

  Future<ReaderVideoMatch> adaptation(String bookId) async {
    if (!_declares(NovelCapability.adaptation)) {
      return _legacy!._api.readerVideoMatch(bookId);
    }
    final data = await _json!._get(['books', _id(bookId), 'adaptation']);
    final series = _text(data['seriesId']);
    if (series.isEmpty) return ReaderVideoMatch.empty;
    return ReaderVideoMatch(
      seriesId: _id(series),
      lastMatchedChapterId: _text(data['lastMatchedChapterId']),
      chapters: {
        for (final row in _entries(data['chapters']))
          _id(row['chapterId']): ReaderVideoChapter(
            row['seriesId'] == null ? series : _id(row['seriesId']),
            _id(row['videoId']),
          ),
      },
      covers: const {},
    );
  }

  Future<ChapterIdeas> chapterReviews(String bookId, String itemId) async {
    if (!_declares(NovelCapability.chapterReviews)) {
      return _legacy!._api.chapterIdeas(itemId);
    }
    final data = await _json!._get([
      'books',
      _id(bookId),
      'chapters',
      _id(itemId),
      'reviews',
    ]);
    return ChapterIdeas(
      itemVersion: _text(data['version']),
      chapterEndIndex: switch (data['chapterEndIndex']) {
        final int index when index >= 0 => index,
        _ => null,
      },
      paragraphs: [
        for (final row in _entries(data['items']))
          if (row['index'] case final int index when index >= 0)
            ParagraphIdeas(
              paraIndex: index,
              count: _integer(row['count']),
              userCount: _integer(row['userCount']),
              isAuthor: row['isAuthor'] == true,
              commentIds: row['commentIds'] is List
                  ? (row['commentIds'] as List).whereType<String>().toList()
                  : const [],
            ),
      ],
    );
  }

  Future<BookCommentPage> paragraphReviews(
    String bookId,
    String itemId, {
    required int index,
    required String version,
    String? cursor,
  }) async {
    if (!_declares(NovelCapability.chapterReviews)) {
      return _legacy!._api.paragraphComments(
        bookId,
        itemId,
        itemVersion: version,
        paraIndex: index,
        cursor: cursor,
      );
    }
    final data = await _json!._get(
      [
        'books',
        _id(bookId),
        'chapters',
        _id(itemId),
        'paragraphs',
        '$index',
        'reviews',
      ],
      {'cursor': ?cursor},
    );
    return _reviews(data, offset: int.tryParse(cursor ?? '') ?? 0);
  }

  NovelAudioSession? audioSession(String bookId, List<Chapter> chapters) {
    if (!supports(NovelCapability.audio)) return null;
    if (!_declares(NovelCapability.audio)) {
      return NovelAudioSession(bookId, chapters, _legacy!._api);
    }
    final source = _plugin!.id;
    final scopedBook = _audioId([source, bookId]);
    final mapping = <String, Chapter>{};
    final scopedChapters = <Chapter>[
      for (final chapter in chapters)
        Chapter(
          itemId: _audioId([source, bookId, chapter.itemId]),
          title: chapter.title,
          volumeName: chapter.volumeName,
          version: chapter.version,
          disabled: chapter.disabled,
        ),
    ];
    for (var index = 0; index < chapters.length; index++) {
      mapping[scopedChapters[index].itemId] = chapters[index];
    }
    return NovelAudioSession(
      scopedBook,
      scopedChapters,
      _PluginAudioClient(this, bookId, scopedChapters, mapping),
    );
  }

  Future<BookCommentPage> bookReviews(String bookId, {int offset = 0}) async {
    if (!_declares(NovelCapability.bookReviews)) {
      return _legacy!._api.bookComments(bookId, offset: offset);
    }
    final result = await _json!._get(
      ['books', _id(bookId), 'reviews'],
      {'offset': '$offset'},
    );
    return _reviews(result, offset: offset);
  }

  BookCommentPage _reviews(Map<String, dynamic> result, {required int offset}) {
    final rawCursor = _text(result['nextCursor']);
    final cursor = rawCursor.isEmpty ? null : _cursor(rawCursor);
    final nextOffset = _integer(result['nextOffset']);
    return BookCommentPage(
      comments: [for (final entry in _list(result['items'])) ?_review(entry)],
      totalCount: result['totalCount'] is int ? result['totalCount'] as int : 0,
      hasMore: cursor != null || nextOffset > offset,
      nextOffset: nextOffset,
      nextCursor: cursor,
    );
  }

  BookComment? _review(Object? raw) {
    final value = _object(raw);
    final text = _text(value['text']);
    final images = value['imageUrls'];
    final comment = BookComment(
      id: _text(value['id']),
      text: text,
      imageUrls: images is List
          ? images.map(_allowedMediaUrl).where((url) => url.isNotEmpty).toList()
          : const [],
      userName: _text(value['userName']),
      userAvatar: _allowedMediaUrl(value['userAvatar']),
      score: value['score'] is int ? value['score'] as int : 0,
      diggCount: _integer(value['diggCount']),
      replyCount: value['replyCount'] is int ? value['replyCount'] as int : 0,
      isAuthor: value['isAuthor'] == true,
    );
    return comment.isEmpty ? null : comment;
  }

  bool get canPageCommentReplies =>
      _json != null && _declares(NovelCapability.commentReplies);

  Future<CommentReplyPage> commentReplies(
    String bookId,
    String commentId, {
    String? chapterId,
    String? cursor,
  }) async {
    if (!_declares(NovelCapability.commentReplies)) {
      return _legacy!._api.commentReplies(
        bookId,
        commentId,
        groupId: chapterId ?? bookId,
        commentSource: chapterId == null ? 501 : 503,
      );
    }
    final data = await _json!._get(
      [
        'books',
        _id(bookId),
        if (chapterId != null) ...['chapters', _id(chapterId)],
        'reviews',
        _id(commentId),
        'replies',
      ],
      {'cursor': ?cursor},
    );
    return CommentReplyPage(
      replies: [
        for (final item in _entries(data['items']))
          if (_review(item) case final reply?)
            CommentReply(
              id: reply.id,
              text: reply.text,
              imageUrls: reply.imageUrls,
              userName: reply.userName,
              userAvatar: reply.userAvatar,
              diggCount: reply.diggCount,
            ),
      ],
      totalCount: _integer(data['totalCount']),
      hasMore: _text(data['nextCursor']).isNotEmpty,
      cursor: _text(data['nextCursor']),
    );
  }
}

Iterable<Map<String, dynamic>> _entries(Object? value) sync* {
  if (value is List) yield* value.whereType<Map<String, dynamic>>();
}

int _integer(Object? value, {int fallback = 0}) =>
    value is int ? value : fallback;

class NovelAudioSession {
  const NovelAudioSession(this.bookId, this.chapters, this.api);

  final String bookId;
  final List<Chapter> chapters;
  final ApiClient api;
}

String _audioId(List<String> parts) =>
    'plugin_${sha256.convert(utf8.encode(jsonEncode(parts)))}';

class _PluginAudioClient extends ApiClient {
  _PluginAudioClient(this._source, this._bookId, this._chapters, this._original)
    : super(baseUrl: '$_packageOrigin');

  final NovelSourceCapabilities _source;
  final String _bookId;
  final List<Chapter> _chapters;
  final Map<String, Chapter> _original;

  _JsonNovelSource get _sourceApi => _source._json!;

  @override
  Future<AudioSource> audioSource(
    String itemId, {
    String? toneId,
    String? bookId,
  }) async {
    final chapter = _original[itemId];
    if (chapter == null) throw const FormatException('音频章节不属于此书源');
    final tone = toneId == null || toneId.isEmpty ? '0' : _id(toneId);
    final payload = await _sourceApi._get(
      ['books', _bookId, 'chapters', chapter.itemId, 'audio'],
      {'voice': tone},
    );
    final url = _source._allowedMediaUrl(payload['url']);
    final key = _text(payload['keyHex']);
    final durationMs = payload['durationMs'];
    if (url.isEmpty ||
        (key.isNotEmpty && !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(key))) {
      throw const FormatException('书源音频地址或密钥无效');
    }
    return AudioSource(
      itemId: itemId,
      url: url,
      toneId: tone,
      keyHex: key,
      duration: durationMs is int && durationMs > 0
          ? Duration(milliseconds: durationMs)
          : null,
    );
  }

  @override
  Future<AudioToneSet> bookTones(String bookId) async {
    final payload = await _sourceApi._get(['books', _bookId, 'voices']);
    return AudioToneSet(
      narratorTones: [
        for (final raw in _list(payload['items']))
          AudioTone(
            id: _id(_object(raw)['id']),
            title: _requiredText(_object(raw)['title']),
          ),
      ],
    );
  }

  @override
  Future<List<AudioVoice>> audioVoices(String bookId) async => [
    for (final tone in (await bookTones(bookId)).narratorTones)
      AudioVoice(id: tone.id, label: tone.title),
  ];

  @override
  Future<SubtitleTrack> chapterTimeline(
    String itemId, {
    String toneId = '1',
    int genre = 1,
    Future<void>? cancel,
    Duration? timeout,
  }) async {
    final chapter = _original[itemId];
    if (chapter == null || !_source.supports(NovelCapability.audioTimeline)) {
      return SubtitleTrack.empty;
    }
    final payload = await _sourceApi
        ._get(
          ['books', _bookId, 'chapters', chapter.itemId, 'subtitles'],
          {'voice': toneId},
        )
        .timeout(timeout ?? _JsonNovelSource._timeout);
    final cues = [
      for (final raw in _list(payload['items']))
        if (_object(raw)['startMs'] case final int start when start >= 0)
          SubtitleCue(startMs: start, text: _text(_object(raw)['text'])),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    return SubtitleTrack(cues);
  }

  @override
  Future<AudioTimeTrack> chapterTimePoints(
    String bookId,
    String itemId, {
    String toneId = '0',
    int reqType = 3,
    Future<void>? cancel,
    Duration? timeout,
  }) async {
    final chapter = _original[itemId];
    if (chapter == null || !_source.supports(NovelCapability.audioTimeline)) {
      return AudioTimeTrack.empty;
    }
    final payload = await _sourceApi
        ._get(
          ['books', _bookId, 'chapters', chapter.itemId, 'timepoints'],
          {'voice': toneId},
        )
        .timeout(timeout ?? _JsonNovelSource._timeout);
    return AudioTimeTrack.fromPayload(payload, audioItemId: itemId);
  }

  @override
  Future<ChapterContent> chapterContent(String itemId) async {
    final chapter = _original[itemId];
    if (chapter == null) throw const FormatException('章节不属于此书源');
    return _sourceApi.chapter(_bookId, chapter);
  }

  @override
  Future<String> contentText(
    String itemId, {
    String tab = '小说',
    Duration? timeout,
  }) async => (await chapterContent(itemId)).legacyText;

  @override
  Future<BookDetail> bookDetail(String bookId) => _sourceApi.detail(_bookId);

  @override
  Future<List<RelatedWork>> relatedWorks(String bookId) =>
      _source.supports(NovelCapability.relatedWorks)
      ? _source.relatedWorks(_bookId)
      : Future.value(const []);

  @override
  Future<List<List<Chapter>>> directoryChapters(
    String bookId, {
    String? tab,
  }) async => [_chapters];

  @override
  Future<ChapterSummary> chapterSummaries(
    String bookId,
    List<String> itemIds,
  ) async => ChapterSummary.empty;

  @override
  Future<BookCommentPage> bookComments(
    String bookId, {
    int offset = 0,
    int count = 10,
  }) => _source.supports(NovelCapability.bookReviews)
      ? _source.bookReviews(_bookId, offset: offset)
      : Future.value(const BookCommentPage());
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/author_profile.dart';
import '../models/audio_extra.dart';
import '../models/audio_time_track.dart';
import '../models/chapter_media.dart';
import '../models/chapter_summary.dart';
import '../models/book_comment.dart';
import '../models/chapter_ideas.dart';
import '../models/reader_video_match.dart';
import '../models/book_detail.dart';
import '../models/category_front.dart';
import '../models/comment_reply.dart';
import '../models/home_cell.dart';
import '../models/rank.dart';
import '../models/search_discovery.dart';
import '../models/media_item.dart';
import '../models/shelf_identity.dart';
import '../models/shuqi_book.dart';
import '../src/rust/api.dart' as rust;
import 'api_client.dart';
import 'backend_transport.dart';
import 'chapter_text_formatter.dart';
import 'secure_key_provider.dart';
import 'shuqi_reader_source.dart';

part 'novel_source_capabilities.dart';

class NovelPlugin {
  NovelPlugin.fromMetadata(Map<String, dynamic> data)
    : id = _text(data['sourceId']),
      name = nativeNames[data['sourceId']] ?? _text(data['name']),
      version = _text(data['version']),
      publisher = _text(data['publisher']),
      usesNativeProtocol = data['protocol'] == 'native-v1',
      hasBookstoreFeed =
          data['sourceId'] == 'fanqie' && data['bookstoreFeed'] == true,
      hasFullFanqieExperience =
          data['sourceId'] == 'fanqie' &&
          data['protocol'] == 'native-v1' &&
          data['fanqieFullExperience'] == true,
      needsReimport = data['legacyPublisher'] == true,
      capabilities = _readCapabilities(data['capabilities']),
      channels = _readChannels(data['channels']),
      searchFilters = _readSearchFilters(
        data['searchFilters'],
        native: data['protocol'] == 'native-v1',
      ),
      httpsHosts = Set.unmodifiable(
        data['httpsHosts'] is List
            ? (data['httpsHosts'] as List).whereType<String>()
            : const <String>[],
      );

  static const nativeNames = {'fanqie': '番茄', 'shuqi': '书旗'};
  final String id;
  final String name;
  final String version;
  final String publisher;
  final bool usesNativeProtocol;
  final bool hasBookstoreFeed;
  final bool hasFullFanqieExperience;
  final bool needsReimport;
  final Set<NovelCapability> capabilities;
  final List<NovelHomeChannel> channels;
  final List<NovelSearchFilter> searchFilters;
  final Set<String> httpsHosts;

  bool samePackage(NovelPlugin other) =>
      id == other.id &&
      version == other.version &&
      publisher == other.publisher &&
      needsReimport == other.needsReimport;
}

typedef NovelSearchPage = ({List<MediaItem> items, String? nextCursor});

typedef NovelBookstorePage = ({
  List<MediaItem> items,
  int? nextOffset,
  String? sessionId,
  List<HomeCell> cells,
});

enum NovelBookstoreChannel { recommended, novels }

abstract class NovelSource {
  Future<NovelSearchPage> search(String query, {String? cursor});
  Future<MediaItem> book(String bookId);
  Future<List<Chapter>> directory(String bookId);
  Future<ChapterContent> chapter(String bookId, Chapter chapter);

  Future<BookDetail> detail(String bookId) async {
    final item = await book(bookId);
    return BookDetail(
      bookId: bookId,
      title: item.title,
      author: BookAuthor(name: item.author),
      abstract: item.intro,
      cover: item.cover,
      tags: item.categories,
      creationStatus: item.creationStatus,
      wordNumber: item.wordNumber,
      source: item.source,
    );
  }

  Future<List<List<Chapter>>> volumes(String bookId) async => [
    await directory(bookId),
  ];
  ApiClient? get fullApi => null;
  NovelSourceCapabilities get optional => const NovelSourceCapabilities();
  void close();
}

typedef NovelZipBridge =
    Future<Uint8List> Function(
      String action,
      Map<String, String> arguments,
      Uint8List archive,
    );

class NovelPluginRegistry extends ChangeNotifier {
  NovelPluginRegistry({
    this.supportsZipPackages = false,
    NovelZipBridge? bridge,
  }) : _bridge = bridge ?? _runNative;

  static final instance = NovelPluginRegistry(
    supportsZipPackages: Platform.isAndroid || Platform.isWindows,
  );
  static const _maximumZipBytes = 16 * 1024 * 1024;

  final bool supportsZipPackages;
  final NovelZipBridge _bridge;
  final _packages = <String, NovelPlugin>{};
  final _sources = <String, NovelSource>{};
  Future<void>? _pendingLoad;
  bool _loaded = false;
  Future<void> _writes = Future.value();

  List<NovelPlugin> get plugins => [
    for (final package in _packages.values)
      if (!package.needsReimport) package,
  ];
  List<NovelPlugin> get legacyPlugins => [
    for (final package in _packages.values)
      if (package.needsReimport) package,
  ];
  NovelPlugin? plugin(String id) {
    final package = _packages[id];
    return package?.needsReimport == true ? null : package;
  }

  Future<void> load() async {
    if (_loaded || !supportsZipPackages) return;
    final pending = _pendingLoad ??= _refresh();
    try {
      await pending;
    } finally {
      if (identical(_pendingLoad, pending)) _pendingLoad = null;
    }
  }

  Future<void> _refresh() async {
    final rows = _list(await _metadata('list'));
    final next = <String, NovelPlugin>{};
    for (final row in rows) {
      final package = NovelPlugin.fromMetadata(_object(row));
      final previous = _packages[package.id];
      next[package.id] = previous != null && previous.samePackage(package)
          ? previous
          : package;
    }
    for (final id in _packages.keys) {
      if (!identical(_packages[id], next[id])) _sources.remove(id)?.close();
    }
    _packages
      ..clear()
      ..addAll(next);
    _loaded = true;
    notifyListeners();
  }

  NovelSource source(String id) {
    final package = plugin(id);
    if (package == null) throw const FormatException('请先导入此书源的 ZIP 插件');
    return _sources.putIfAbsent(id, () {
      final client = _WasmSourceClient(package, _bridge);
      return package.usesNativeProtocol
          ? _NativeNovelSource(package, client)
          : _JsonNovelSource(package, client);
    });
  }

  ApiClient? get fanqieApi =>
      plugin('fanqie') == null ? null : source('fanqie').fullApi;

  Future<NovelBookstorePage> bookstorePage(
    NovelBookstoreChannel channel, {
    int offset = 0,
    String? sessionId,
  }) {
    if (plugin('fanqie')?.hasBookstoreFeed != true) {
      throw const FormatException('请更新书源插件');
    }
    return (source('fanqie') as _NativeNovelSource).bookstorePage(
      channel,
      offset: offset,
      sessionId: sessionId,
    );
  }

  Future<Map<String, dynamic>> inspectZip(String path) async =>
      _object(await _metadata('inspect', archive: await _readArchive(path)));

  Future<void> installZip(
    String path,
    String fingerprint, {
    String? resetPublisher,
  }) => _enqueue(() async {
    await load();
    await _metadata(
      'install',
      arguments: {
        'fingerprint': fingerprint,
        'resetPublisher': ?resetPublisher,
      },
      archive: await _readArchive(path),
    );
    await _refresh();
  });

  Future<void> uninstall(String id) => _enqueue(() async {
    await _metadata('uninstall', arguments: {'sourceId': id});
    await _refresh();
  });

  Future<Object?> _metadata(
    String action, {
    Map<String, String> arguments = const {},
    Uint8List? archive,
  }) async {
    final bytes = await _bridge(action, arguments, archive ?? Uint8List(0));
    return _object(jsonDecode(utf8.decode(bytes)))['value'];
  }

  static Future<Uint8List> _readArchive(String path) async {
    final buffer = BytesBuilder(copy: false);
    await for (final part in File(path).openRead()) {
      if (buffer.length + part.length > _maximumZipBytes) {
        throw const ApiException('书源 ZIP 超出 16 MiB');
      }
      buffer.add(part);
    }
    return buffer.takeBytes();
  }

  static Future<void>? _storageReady;

  static Future<void> _prepareStorage() async {
    final key = await SecureKeyProvider.instance.devicePoolKey();
    if (key == null) throw const FormatException('书源安全存储不可用');
    await rust.setDevicePoolKey(key: key);
  }

  static Future<Uint8List> _runNative(
    String action,
    Map<String, String> arguments,
    Uint8List archive,
  ) async {
    await RustBackendTransport.ensureRuntime();
    if (action == 'request') {
      final ready = _storageReady ??= _prepareStorage();
      try {
        await ready;
      } catch (_) {
        if (identical(ready, _storageReady)) _storageReady = null;
        rethrow;
      }
    }
    final root = await getApplicationSupportDirectory();
    try {
      return await rust.novelZipOperate(
        supportDir: root.path,
        action: action,
        arguments: jsonEncode(arguments),
        archive: archive,
      );
    } on String catch (message) {
      throw ApiException(message);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  void dispose() {
    for (final source in _sources.values) {
      source.close();
    }
    super.dispose();
  }
}

Future<void> ensureNovelAccountImport() async {
  final registry = NovelPluginRegistry.instance;
  if (!registry.supportsZipPackages) return;
  await registry.load();
  if (registry.plugin('fanqie') == null ||
      !registry
          .source('fanqie')
          .optional
          .supports(NovelCapability.accountImport)) {
    throw const ApiException('请先导入支持在线账号导入的新版番茄 ZIP');
  }
}

class _WasmSourceClient extends http.BaseClient {
  _WasmSourceClient(this.plugin, this._bridge);

  final NovelPlugin plugin;
  final NovelZipBridge _bridge;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET' &&
        !(plugin.hasFullFanqieExperience &&
            request.method == 'POST' &&
            request.url.path.startsWith('/api/v1/comments/') &&
            request.url.path.endsWith('/replies'))) {
      throw UnsupportedError(request.method);
    }
    final bytes = await _bridge('request', {
      'sourceId': plugin.id,
      'version': plugin.version,
      'publisher': plugin.publisher,
      if (request.method != 'GET') 'method': request.method,
      'path': request.url.path,
      'query': request.url.query,
    }, Uint8List(0));
    if (bytes.length < 4) throw const FormatException('书源未返回数据');
    final status = ByteData.sublistView(bytes).getInt32(0);
    return http.StreamedResponse(
      Stream.value(Uint8List.sublistView(bytes, 4)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}

// The platform client transports these requests directly to the installed
// provider. This origin is only used to construct request paths.
final _packageOrigin = Uri.https('novel-source.invalid');

class _NativeNovelSource extends NovelSource {
  _NativeNovelSource(this.plugin, http.Client client)
    : _client = _ScopedNovelClient(client);

  final NovelPlugin plugin;
  final _ScopedNovelClient _client;
  late final _api = ApiClient(baseUrl: '$_packageOrigin', client: _client);
  final _active = <BackendRequest>{};
  bool _closed = false;
  String get id => plugin.id;
  bool get _shuqi => id == 'shuqi';

  @override
  ApiClient? get fullApi => plugin.hasFullFanqieExperience ? _api : null;

  @override
  late final NovelSourceCapabilities optional = NovelSourceCapabilities._(
    plugin,
    legacy: this,
    json: _JsonNovelSource.withClient(plugin, _client),
  );

  @override
  Future<BookDetail> detail(String bookId) =>
      _shuqi ? super.detail(bookId) : _request(() => _api.bookDetail(bookId));

  @override
  Future<List<List<Chapter>>> volumes(String bookId) => _shuqi
      ? super.volumes(bookId)
      : _request(() => _api.directoryChapters(bookId));

  Future<NovelBookstorePage> bookstorePage(
    NovelBookstoreChannel channel, {
    required int offset,
    required String? sessionId,
  }) => _request(() async {
    final tabType = channel == NovelBookstoreChannel.recommended ? 2 : 25;
    final page = await _api.homepagePage(
      tabType: tabType,
      offset: offset,
      sessionId: sessionId,
    );
    if (page.tabScoped && page.answeredTabType != tabType) {
      throw const FormatException('番茄返回了其他栏目');
    }
    final books = <String, MediaItem>{};
    final stream = page.cells
        .where(
          (cell) => const {
            kHomeCellMixedFeedShowType,
            kHomeCellDoubleRowFeedShowType,
          }.contains(cell.showType),
        )
        .expand((cell) => cell.flatten())
        .where((item) => item.kind == 'book')
        .toList();
    for (final item in stream.isEmpty ? page.items : stream) {
      if (item.kind == 'book' && item.id.isNotEmpty) {
        books.putIfAbsent(item.id, () => item.copyWith(source: id));
      }
    }
    final next = page.nextOffset;
    return (
      items: books.values.toList(),
      nextOffset: next != null && next > offset ? next : null,
      sessionId: page.sessionId ?? sessionId,
      cells: page.cells,
    );
  });

  Future<NovelBookstorePage> channelPage(
    String channel, {
    required int offset,
    required String? sessionId,
  }) {
    if (channel == 'recommended' || channel == 'novels') {
      return bookstorePage(
        channel == 'recommended'
            ? NovelBookstoreChannel.recommended
            : NovelBookstoreChannel.novels,
        offset: offset,
        sessionId: sessionId,
      );
    }
    return _request(() async {
      if (channel == 'stories') {
        final page = await _api.ugcStories(
          offset: offset,
          sessionId: sessionId,
        );
        return (
          items: [
            for (final story in page.items)
              if (story.relatedBookId.isNotEmpty)
                MediaItem(
                  id: story.relatedBookId,
                  title: story.title,
                  cover: story.cover,
                  author: story.author,
                  badge: '',
                  ep: '',
                  kind: 'book',
                  intro: story.summary,
                  source: id,
                ),
          ],
          cells: const <HomeCell>[],
          nextOffset: page.hasMore ? page.nextOffset : null,
          sessionId: page.sessionId ?? sessionId,
        );
      }
      if (channel == 'comics' || channel == 'audiobooks') {
        final manga = channel == 'comics';
        final kind = manga ? 'manga' : 'audio';
        final tabs = await _api.searchTabs(
          manga ? '漫画' : '听书',
          tabType: manga ? 8 : 2,
          offset: offset,
          pluginMedia: true,
        );
        final tab = tabs
            .where((tab) => tab.items.any((item) => item.kind == kind))
            .firstOrNull;
        return (
          items: [
            for (final item in tab?.items ?? <MediaItem>[])
              if (item.kind == kind) item.copyWith(source: id),
          ],
          cells: const <HomeCell>[],
          nextOffset: tab?.hasMore == false ? null : tab?.nextOffset,
          sessionId: null,
        );
      }
      final tabType = switch (channel) {
        'dramas' => 8,
        'animated' => 24,
        _ => throw const FormatException('此书源没有该栏目'),
      };
      final kind = channel == 'dramas' ? 'video' : 'manju';
      final page = await _api.homepagePage(
        tabType: tabType,
        offset: offset,
        sessionId: sessionId,
        pluginMedia: true,
      );
      if (page.tabScoped && page.answeredTabType != tabType) {
        throw const FormatException('书源返回了其他栏目');
      }
      return (
        items: [
          for (final item in page.items)
            if (item.kind == kind) item.copyWith(source: id),
        ],
        cells: const <HomeCell>[],
        nextOffset: page.nextOffset,
        sessionId: page.sessionId ?? sessionId,
      );
    });
  }

  Future<T> _request<T>(Future<T> Function() body) async {
    if (_closed) throw StateError('书源已卸载或更新');
    final request = BackendRequest();
    _active.add(request);
    try {
      return await _api.withCancellation(request, body);
    } finally {
      _active.remove(request);
    }
  }

  @override
  Future<NovelSearchPage> search(String query, {String? cursor}) =>
      _request(() async {
        if (_shuqi) {
          final payload = await _api.shuqiSearch(query);
          return (
            items: [
              for (final item in _list(payload['data']))
                shuqiMediaItemFromSearch(_object(item)),
            ],
            nextCursor: null,
          );
        }
        final offset = cursor == null ? 0 : int.parse(cursor);
        final tabs = await _api.searchTabs(query, tabType: 3, offset: offset);
        final tab = tabs
            .where((tab) => tab.title == '小说' || tab.title == '书籍')
            .firstOrNull;
        final next = tab?.nextOffset;
        return (
          items: tab?.items.where((item) => item.kind == 'book').toList() ?? [],
          nextCursor: next != null && next > offset && tab?.hasMore != false
              ? '$next'
              : null,
        );
      });

  @override
  Future<MediaItem> book(String bookId) => _request(() async {
    if (_shuqi) {
      final payload = await _api.shuqiBook(bookId);
      return ShuqiBook.fromJson(
        _object(payload['data']),
      ).toMediaItem().copyWith(id: bookId);
    }
    final detail = await _api.bookDetail(bookId);
    return MediaItem(
      id: bookId,
      title: detail.title,
      cover: detail.cover,
      author: detail.author.name,
      badge: '',
      ep: '',
      kind: 'book',
      intro: detail.abstract,
      categories: detail.tags,
      source: id,
    );
  });

  @override
  Future<List<Chapter>> directory(String bookId) => _request(
    () async => _shuqi
        ? loadShuqiDirectory(bookId, loader: _api.shuqiToc)
        : [
            for (final volume in await _api.directoryChapters(bookId))
              ...volume,
          ],
  );

  @override
  Future<ChapterContent> chapter(String bookId, Chapter chapter) => _request(
    () async => _shuqi
        ? ChapterContent.fromPlainText(
            await loadShuqiChapter(bookId, chapter, loader: _api.shuqiChapter),
            illustrationsChecked: true,
          )
        : _api.chapterContent(chapter.itemId),
  );

  @override
  void close() {
    _closed = true;
    for (final request in _active) {
      request.cancel();
    }
    _client.close();
  }
}

/// Releases callers when a source is replaced. In-progress WASM requests
/// can finish in Rust, and their results are discarded here.
class _ScopedNovelClient extends http.BaseClient {
  _ScopedNovelClient(this._client);

  final http.Client _client;
  final _inFlight = <Completer<http.StreamedResponse>>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) throw StateError('书源已卸载或更新，请重新打开');
    final reply = Completer<http.StreamedResponse>();
    _inFlight.add(reply);
    unawaited(
      Future.sync(() => _client.send(request)).then(
        (response) {
          if (_inFlight.remove(reply)) reply.complete(response);
        },
        onError: (Object error, StackTrace stack) {
          if (_inFlight.remove(reply)) reply.completeError(error, stack);
        },
      ),
    );
    return reply.future;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final reply in _inFlight) {
      reply.completeError(StateError('书源已卸载或更新，请重新打开'));
    }
    _inFlight.clear();
    _client.close();
  }
}

class _JsonNovelSource extends NovelSource {
  _JsonNovelSource(this.plugin, http.Client client)
    : _client = _ScopedNovelClient(client);

  _JsonNovelSource.withClient(this.plugin, this._client);

  @override
  late final NovelSourceCapabilities optional = NovelSourceCapabilities._(
    plugin,
    json: this,
  );

  final NovelPlugin plugin;
  final _ScopedNovelClient _client;
  static const _timeout = Duration(seconds: 20);

  Future<Map<String, dynamic>> _get(
    List<String> path, [
    Map<String, String>? query,
  ]) async {
    final base = _packageOrigin;
    final uri = base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'v1',
        ...path,
      ],
      queryParameters: query,
    );
    final abort = Completer<void>();
    try {
      return await (() async {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        )..headers['accept'] = 'application/json';
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          throw FormatException('书源请求失败（HTTP ${response.statusCode}）');
        }
        final bytes = await response.stream.toBytes();
        return _object(jsonDecode(utf8.decode(bytes)));
      })().timeout(_timeout);
    } finally {
      abort.complete();
    }
  }

  MediaItem _item(Map<String, dynamic> json) => MediaItem(
    id: _id(json['bookId']),
    title: _requiredText(json['title']),
    cover: _mediaUrl(json['coverUrl']),
    author: _text(json['author']),
    badge: '',
    ep: '',
    kind: 'book',
    intro: _text(json['intro']),
    score: switch (json['score']) {
      final num score when score > 0 && score <= 10 => score.toDouble(),
      _ => null,
    },
    categories: json['tags'] is List
        ? (json['tags'] as List).whereType<String>().toList(growable: false)
        : const [],
    creationStatus: json['creationStatus'] is int
        ? json['creationStatus'] as int
        : -1,
    wordNumber: json['wordNumber'] is int ? json['wordNumber'] as int : 0,
    source: plugin.id,
  );

  @override
  Future<NovelSearchPage> search(String query, {String? cursor}) async {
    return _searchWithFilters(query, cursor: cursor, filters: const {});
  }

  Future<NovelSearchPage> _searchWithFilters(
    String query, {
    String? cursor,
    required Map<String, String> filters,
  }) async {
    final page = await _get(
      ['search'],
      {
        'q': query,
        'cursor': ?cursor,
        if (filters.isNotEmpty) 'filters': jsonEncode(filters),
      },
    );
    return (
      items: [for (final item in _list(page['items'])) _item(_object(item))],
      nextCursor: _cursor(page['nextCursor']),
    );
  }

  @override
  Future<MediaItem> book(String bookId) async {
    final item = _item(await _get(['books', _id(bookId)]));
    if (item.id != bookId) throw const FormatException('书源返回了其他书籍');
    return item;
  }

  @override
  Future<BookDetail> detail(String bookId) async {
    final payload = await _get(['books', _id(bookId)]);
    final item = _item(payload);
    if (item.id != bookId) throw const FormatException('书源返回了其他书籍');
    return BookDetail(
      bookId: bookId,
      title: item.title,
      author: BookAuthor(name: item.author, id: _text(payload['authorId'])),
      abstract: item.intro,
      cover: item.cover,
      tags: item.categories,
      creationStatus: item.creationStatus,
      wordNumber: item.wordNumber,
      source: item.source,
    );
  }

  @override
  Future<List<Chapter>> directory(String bookId) async {
    final result = <Chapter>[];
    final ids = <String>{};
    final cursors = <String>{};
    String? cursor;
    do {
      final page = await _get(
        ['books', _id(bookId), 'chapters'],
        {'cursor': ?cursor},
      );
      for (final entry in _list(page['items'])) {
        final item = _object(entry);
        final id = _id(item['chapterId']);
        if (ids.add(id)) {
          result.add(
            Chapter(
              itemId: id,
              title: _requiredText(item['title']),
              volumeName: _text(item['volumeName']),
              version: _text(item['version']),
            ),
          );
        }
      }
      cursor = _cursor(page['nextCursor']);
      if (result.length > 50000 ||
          (cursor != null && (cursors.length >= 200 || !cursors.add(cursor)))) {
        throw const FormatException('书源目录分页异常或超出限制');
      }
    } while (cursor != null);
    return result;
  }

  @override
  Future<ChapterContent> chapter(String bookId, Chapter chapter) async {
    final response = await _get([
      'books',
      _id(bookId),
      'chapters',
      _id(chapter.itemId),
    ]);
    final blocks = <ChapterBlock>[];
    for (final raw in _list(response['blocks'])) {
      final block = _object(raw);
      switch (block['type']) {
        case 'paragraph':
          blocks.add(
            ChapterParagraph(
              _requiredText(block['text']),
              paraIndex: switch (block['paraIndex']) {
                final int index when index >= 0 => index,
                _ => null,
              },
            ),
          );
        case 'image':
          final url = _mediaUrl(block['url']);
          if (url.isNotEmpty) {
            blocks.add(ChapterImage(url: url, alt: _text(block['alt'])));
          }
        default:
          throw const FormatException('未知的正文区块');
      }
    }
    if (blocks.isEmpty) throw const FormatException('书源未返回正文');
    return ChapterContent(
      blocks: blocks,
      illustrationsChecked: response['illustrationsChecked'] != false,
    );
  }

  @override
  void close() => _client.close();
}

Map<String, dynamic> _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('书源数据格式无效');
}

List<dynamic> _list(Object? value) {
  if (value is List) return value;
  throw const FormatException('书源列表格式无效');
}

String _text(Object? value) => value is String ? value : '';

String _requiredText(Object? value) {
  final text = _text(value);
  if (text.trim().isEmpty) throw const FormatException('书源缺少必填文本');
  return text;
}

String? _cursor(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty && value.length <= 1024) return value;
  throw const FormatException('书源分页游标无效');
}

String _id(Object? value) {
  if (value is String && ShelfIdentity.isValidContentId(value)) return value;
  throw const FormatException('书籍或章节标识无效');
}

String _mediaUrl(Object? value) {
  final url = value is String ? Uri.tryParse(value) : null;
  return url != null &&
          url.scheme == 'https' &&
          url.host.isNotEmpty &&
          url.userInfo.isEmpty
      ? '$url'
      : '';
}

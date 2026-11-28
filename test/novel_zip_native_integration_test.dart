import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_plugins.dart';
import 'package:fqapp/src/rust/api.dart';
import 'package:fqapp/src/rust/frb_generated.dart';

void main() {
  final library = Platform.environment['FQAPP_RUST_HOST_LIB'];
  final fixtures = Platform.environment['FQAPP_NOVEL_ZIP_FIXTURES'];
  final qimaoOnline = Platform.environment['FQAPP_TEST_QIMAO_ONLINE'] == '1';
  test(
    'Qimao comment anchors survive the chapter cache and can load comments and replies',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      addTearDown(RustLib.dispose);
      final storage = await Directory.systemTemp.createTemp(
        'fq-qimao-reviews-',
      );
      addTearDown(() => storage.delete(recursive: true));
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, arguments, archive) async {
          final bytes = await novelZipOperate(
            supportDir: storage.path,
            action: action,
            arguments: jsonEncode(arguments),
            archive: archive,
          );
          if (action == 'request' &&
              ByteData.sublistView(bytes).getInt32(0) != 200) {
            fail('${arguments['path']}: ${utf8.decode(bytes.sublist(4))}');
          }
          return bytes;
        },
      );
      addTearDown(registry.dispose);
      for (final version in ['1.0.1', '1.0.2']) {
        final path = '$fixtures/qimao-plugin-$version.zip';
        final info = await registry.inspectZip(path);
        expect(info['resetPublisher'], isNull);
        await registry.installZip(path, info['fingerprint'] as String);
      }
      expect(registry.plugin('qimao')?.version, '1.0.2');

      const bookId = '195958';
      const chapterId = '499610';
      final source = registry.source('qimao');
      final comments = source.optional;
      expect(comments.supports(NovelCapability.chapterReviews), true);
      expect(comments.canPageCommentReplies, true);
      final chapter = Chapter(itemId: chapterId, title: '第1章', volumeName: '');
      final content = await source.chapter(bookId, chapter);
      final cached = ChapterContent.fromCacheText(content.toCacheText());
      final anchors = cached.blocks
          .whereType<ChapterParagraph>()
          .map((block) => block.paraIndex)
          .whereType<int>()
          .toSet();
      final ideas = await comments.chapterReviews(bookId, chapterId);
      expect(ideas.bubbleCounts, isNotEmpty);
      expect(anchors, containsAll(ideas.bubbleCounts.keys));
      expect(anchors, isNot(contains(ideas.endIndex)));
      expect(ideas.endCount, greaterThan(0));
      final active = ideas.withIdeas
          .where((bucket) => bucket.paraIndex != ideas.endIndex)
          .reduce((a, b) => a.count > b.count ? a : b);

      final first = await comments.paragraphReviews(
        bookId,
        chapterId,
        index: active.paraIndex,
        version: ideas.itemVersion,
      );
      expect(first.comments, isNotEmpty);
      expect(first.nextCursor, isNotNull);
      final next = await comments.paragraphReviews(
        bookId,
        chapterId,
        index: active.paraIndex,
        version: ideas.itemVersion,
        cursor: first.nextCursor,
      );
      expect(next.comments.first.id, isNot(first.comments.first.id));

      final threaded = first.comments.reduce(
        (a, b) => a.replyCount > b.replyCount ? a : b,
      );
      expect(threaded.replyCount, greaterThan(10));
      final replies = await comments.commentReplies(
        bookId,
        threaded.id,
        chapterId: chapterId,
      );
      expect(replies.replies, isNotEmpty);
      expect(replies.hasMore, true);
      final moreReplies = await comments.commentReplies(
        bookId,
        threaded.id,
        chapterId: chapterId,
        cursor: replies.cursor,
      );
      expect(moreReplies.replies.first.id, isNot(replies.replies.first.id));

      final chapterPage = await comments.paragraphReviews(
        bookId,
        chapterId,
        index: ideas.endIndex!,
        version: ideas.itemVersion,
      );
      expect(chapterPage.comments, isNotEmpty);
      expect(chapterPage.comments.first.id, startsWith('c_'));
      final chapterThread = chapterPage.comments.firstWhere(
        (comment) => comment.replyCount > 0,
      );
      expect(
        (await comments.commentReplies(
          bookId,
          chapterThread.id,
          chapterId: chapterId,
        )).replies,
        isNotEmpty,
      );
    },
    skip:
        !Platform.isWindows ||
        library == null ||
        fixtures == null ||
        !qimaoOnline,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Qimao upgrades in place and serves discovery, filters, and reading',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      addTearDown(RustLib.dispose);
      final storage = await Directory.systemTemp.createTemp('fq-qimao-zip-');
      addTearDown(() => storage.delete(recursive: true));
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, arguments, archive) async {
          final bytes = await novelZipOperate(
            supportDir: storage.path,
            action: action,
            arguments: jsonEncode(arguments),
            archive: archive,
          );
          if (action == 'request' &&
              ByteData.sublistView(bytes).getInt32(0) != 200) {
            expect(
              ByteData.sublistView(bytes).getInt32(0),
              200,
              reason: '${arguments['path']}: ${utf8.decode(bytes.sublist(4))}',
            );
          }
          return bytes;
        },
      );
      addTearDown(registry.dispose);

      Future<Map<String, dynamic>> install(String version) async {
        final path = '$fixtures/qimao-plugin-$version.zip';
        final info = await registry.inspectZip(path);
        expect(info['resetPublisher'], isNull);
        await registry.installZip(path, info['fingerprint'] as String);
        return info;
      }

      final old = await install('1.0.0');
      expect(registry.source('qimao').optional.channels, isEmpty);
      final update = await install('1.0.1');
      expect(update['publisher'], old['publisher']);
      final plugin = registry.plugin('qimao')!;
      expect(plugin.version, '1.0.1');
      final source = registry.source('qimao');
      final discovery = source.optional;
      expect(discovery.supports(NovelCapability.rankings), true);
      expect(discovery.channels, hasLength(8));
      expect(discovery.channels.first.id, 'recommended');
      for (final channel in discovery.channels) {
        final page = await discovery.home(channel.id);
        expect(page.items, isNotEmpty, reason: channel.id);
        expect(page.items.first.cover, startsWith('https://'));
        expect(page.items.first.source, 'qimao');
        expect(page.nextCursor, isNull);
      }

      final catalog = await discovery.rankCatalog();
      expect(catalog.tabs, hasLength(4));
      final mustRead = catalog.tabs.singleWhere((tab) => tab.name == '必读榜');
      final girls = catalog.categories.singleWhere((cat) => cat.name == '女生榜');
      final board = await discovery.rankBoard(
        rankId: catalog.rankId,
        algo: mustRead.algo,
        categoryId: girls.id,
      );
      expect(board.entries, isNotEmpty);
      expect(board.entries.first.position, 1);
      expect(board.entries.any((entry) => entry.wordNumber > 0), true);
      expect(board.hasMore, false);
      final ranked = await source.book(board.entries.first.id);
      expect(ranked.title, board.entries.first.title);

      expect(plugin.searchFilters.map((filter) => filter.field), [
        'score',
        'creationStatus',
        'wordNumber',
      ]);
      final search = await source.search('三国');
      expect(search.items, isNotEmpty);
      expect(search.nextCursor, isNotNull);
      final score = plugin.searchFilters.first;
      expect(
        search.items.where((item) => score.matches(item, score.options.first)),
        isNotEmpty,
      );
      final next = await source.search('三国', cursor: search.nextCursor);
      expect(next.items.first.id, isNot(search.items.first.id));
      final book = await source.book(search.items.first.id);
      final chapters = await source.directory(book.id);
      expect(chapters, isNotEmpty);
      final chapter = await source.chapter(book.id, chapters.first);
      expect(chapter.blocks, isNotEmpty);
    },
    skip:
        !Platform.isWindows ||
        library == null ||
        fixtures == null ||
        !qimaoOnline,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Windows bridge verifies and installs ZIPs, including a confirmed publisher reset',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      addTearDown(RustLib.dispose);
      await setDevicePoolKey(key: Uint8List(32));
      final storage = await Directory.systemTemp.createTemp(
        'fq-novel-zip-integration-',
      );
      addTearDown(() => storage.delete(recursive: true));

      final backend = await Directory('${storage.path}/backend').create();
      final config = await File(
        '${backend.path}/config.json',
      ).writeAsString('{}');
      final filter = await File(
        '${backend.path}/filters.json',
      ).writeAsString('{}');
      await init(
        configPath: config.path,
        poolPath: '${backend.path}/devices.json',
        filterPath: filter.path,
        runtimeDir: backend.path,
        port: 0,
        lanShare: false,
        mockUpstreamOrigin: '',
      );
      try {
        for (final path in ['/api/v1/books/42', '/api/v1/shuqi/book']) {
          final response = await request(
            requestId: path,
            method: 'GET',
            path: path,
            query: '',
            body: const [],
            timeoutMs: 2500,
          );
          expect(response.status, 503);
          expect(utf8.decode(response.body), contains('导入'));
        }
      } finally {
        await shutdown();
      }

      Future<Uint8List> invoke(
        String action, {
        Map<String, Object?> args = const {},
        Uint8List? bytes,
      }) => novelZipOperate(
        supportDir: storage.path,
        action: action,
        arguments: jsonEncode(args),
        archive: bytes ?? Uint8List(0),
      );
      Future<dynamic> management(
        String action, {
        Map<String, Object?> args = const {},
        Uint8List? bytes,
      }) async =>
          (jsonDecode(
                utf8.decode(await invoke(action, args: args, bytes: bytes)),
              )
              as Map)['value'];
      Future<Uint8List> zip(String name) =>
          File('$fixtures/$name').readAsBytes();
      final expectedError = throwsA(isA<Object>());
      final fanqie = await zip('fanqie-plugin-1.0.5.zip');
      final old = await zip('fanqie-plugin-1.0.2.zip');
      final shuqi = await zip('shuqi-plugin-1.0.2.zip');
      final fanqieInfo = (await management('inspect', bytes: fanqie)) as Map;

      final legacyPublisher =
          Platform.environment['FQAPP_NOVEL_LEGACY_PUBLISHER']!;
      final root = await Directory('${storage.path}/novel-wasm').create();
      final pin = File('${root.path}/fanqie.publisher');
      final oldZip = File('${root.path}/fanqie.zip');
      final oldData = File('${root.path}/fanqie.data');
      await pin.writeAsString(legacyPublisher);
      await oldZip.writeAsBytes(old);
      await oldData.writeAsString('old private state');

      final listed = await management('list') as List;
      expect((listed.single as Map)['legacyPublisher'], true);
      final inspection = await management('inspect', bytes: fanqie) as Map;
      expect(inspection['resetPublisher'], legacyPublisher);
      final args = {'fingerprint': inspection['fingerprint']};
      final invalidSignature = File('$fixtures/fanqie-invalid-signature.zip');
      if (await invalidSignature.exists()) {
        await expectLater(
          management('inspect', bytes: await invalidSignature.readAsBytes()),
          expectedError,
        );
      }
      await expectLater(
        management('install', args: args, bytes: fanqie),
        expectedError,
      );
      await expectLater(
        management('inspect', bytes: Uint8List.fromList([1, 2, 3])),
        expectedError,
      );
      await expectLater(
        management(
          'install',
          args: {...args, 'resetPublisher': legacyPublisher},
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        expectedError,
      );
      expect(await pin.readAsString(), legacyPublisher);
      expect(await oldData.readAsString(), 'old private state');
      await management(
        'install',
        args: {...args, 'resetPublisher': legacyPublisher},
        bytes: fanqie,
      );
      expect(await pin.readAsString(), fanqieInfo['publisher']);
      expect(await oldData.exists(), false);
      await expectLater(
        management('install', args: args, bytes: fanqie),
        expectedError,
      );

      final lower = File('$fixtures/fanqie-plugin-lower.zip');
      if (await lower.exists()) {
        final bytes = await lower.readAsBytes();
        final info = await management('inspect', bytes: bytes) as Map;
        await expectLater(
          management(
            'install',
            args: {'fingerprint': info['fingerprint']},
            bytes: bytes,
          ),
          expectedError,
        );
      }

      final shuqiInfo = await management('inspect', bytes: shuqi) as Map;
      await management(
        'install',
        args: {'fingerprint': shuqiInfo['fingerprint']},
        bytes: shuqi,
      );
      final reply = await invoke(
        'request',
        args: {
          'sourceId': 'shuqi',
          'version': shuqiInfo['version'],
          'publisher': shuqiInfo['publisher'],
          'path': '/v1/meta',
          'query': '',
        },
      );
      expect(ByteData.sublistView(reply).getInt32(0), 200);
      expect(
        (jsonDecode(utf8.decode(reply.sublist(4))) as Map)['sourceId'],
        'shuqi',
      );

      await management('uninstall', args: {'sourceId': 'fanqie'});
      expect((await management('list') as List).length, 1);
      await management('install', args: args, bytes: fanqie);
      expect((await management('list') as List).length, 2);

      final currentFanqie = File('$fixtures/fanqie-plugin-1.0.7.zip');
      if (await currentFanqie.exists()) {
        final bytes = await currentFanqie.readAsBytes();
        final info = await management('inspect', bytes: bytes) as Map;
        await management(
          'install',
          args: {'fingerprint': info['fingerprint']},
          bytes: bytes,
        );
        final list = await management('list') as List;
        final installed = list.whereType<Map>().singleWhere(
          (row) => row['sourceId'] == 'fanqie',
        );
        expect(installed['capabilities'], containsPair('home', 1));
        expect(installed['capabilities'], containsPair('accountImport', 1));
        expect(
          (installed['channels'] as List).whereType<Map>().map(
            (row) => row['id'],
          ),
          containsAll([
            'recommended',
            'novels',
            'dramas',
            'animated',
            'comics',
            'audiobooks',
            'stories',
          ]),
        );
        final rejectedAccount = await invoke(
          'request',
          args: {
            'sourceId': 'fanqie',
            'version': '1.0.7',
            'publisher': info['publisher'],
            'path': '/v1/account/history',
            'method': 'POST',
            'query': '',
          },
          bytes: Uint8List.fromList(
            utf8.encode(
              '{"cookie":"","offset":0,"last_min_read_timestamp_ms":0,"is_first_load":true}',
            ),
          ),
        );
        expect(ByteData.sublistView(rejectedAccount).getInt32(0), 400);
      }

      final currentShuqi = File('$fixtures/shuqi-plugin-1.0.3.zip');
      if (await currentShuqi.exists()) {
        final bytes = await currentShuqi.readAsBytes();
        final info = await management('inspect', bytes: bytes) as Map;
        await management(
          'install',
          args: {'fingerprint': info['fingerprint']},
          bytes: bytes,
        );
        final list = await management('list') as List;
        expect(
          list.whereType<Map>().singleWhere(
            (row) => row['sourceId'] == 'shuqi',
          )['version'],
          '1.0.3',
        );
      }

      final qimao = File('$fixtures/qimao-plugin-1.0.0.zip');
      if (await qimao.exists()) {
        final bytes = await qimao.readAsBytes();
        final info = await management('inspect', bytes: bytes) as Map;
        await management(
          'install',
          args: {'fingerprint': info['fingerprint']},
          bytes: bytes,
        );
        final list = await management('list') as List;
        final plugin = list.whereType<Map>().singleWhere(
          (row) => row['sourceId'] == 'qimao',
        );
        expect(plugin['protocol'], 'json-v1');
        expect(plugin['capabilities'], isNull);
      }

      final example = File('$fixtures/example-1.0.0.zip');
      if (!await example.exists()) return;
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, arguments, bytes) =>
            invoke(action, args: arguments, bytes: bytes),
      );
      addTearDown(registry.dispose);
      final exampleInfo = await registry.inspectZip(example.path);
      await registry.installZip(
        example.path,
        exampleInfo['fingerprint'] as String,
      );
      final source = registry.source('example_novels');
      final search = await source.search('样书');
      expect(search.items.single.id, '42');
      final detail = await source.detail('42');
      expect(detail.title, '第三方 ZIP 样书');
      expect(detail.author.name, '示例作者');
      final chapter = (await source.volumes('42')).single.single;
      expect(chapter.volumeName, '上卷');
      expect(
        (await source.chapter('42', chapter)).toCacheText(),
        contains('来自真实测试 WASM 的正文'),
      );
      await expectLater(
        registry.inspectZip('$fixtures/example-different-publisher.zip'),
        expectedError,
      );
      final update = '$fixtures/example-1.0.1.zip';
      final updateInfo = await registry.inspectZip(update);
      await registry.installZip(update, updateInfo['fingerprint'] as String);
      expect(registry.plugin('example_novels')?.version, '1.0.1');
      await expectLater(source.detail('42'), expectedError);
    },
    skip: !Platform.isWindows || library == null || fixtures == null,
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/novel_plugin_book_id.dart';
import 'package:fqapp/services/novel_plugins.dart';

Uint8List metadata(Object? data) =>
    Uint8List.fromList(utf8.encode(jsonEncode({'value': data})));

Uint8List frame(Object data) {
  final json = utf8.encode(jsonEncode(data));
  final bytes = Uint8List(json.length + 4)..setRange(4, json.length + 4, json);
  ByteData.sublistView(bytes).setInt32(0, 200);
  return bytes;
}

Map<String, dynamic> package(
  String id,
  String version, {
  bool legacy = false,
}) => {
  'sourceId': id,
  'name': id,
  'version': version,
  'publisher': legacy ? 'old' : 'new',
  'protocol': id == 'example' ? 'json-v1' : 'native-v1',
  if (id == 'fanqie') 'bookstoreFeed': true,
  if (id == 'fanqie') 'fanqieFullExperience': true,
  if (legacy) 'legacyPublisher': true,
};

void main() {
  test('optional reviews and audio use only the declared source', () async {
    final routes = <(String?, String?)>[];
    final registry = NovelPluginRegistry(
      supportsZipPackages: true,
      bridge: (action, args, _) async {
        if (action == 'list') {
          return metadata([
            {
              ...package('example', '1.0.0'),
              'capabilities': {'bookReviews': 1},
            },
            for (final id in ['audio_a', 'audio_b'])
              {
                ...package(id, '1.0.0'),
                'protocol': 'json-v1',
                'capabilities': {'audio': 1},
                'httpsHosts': ['example.com'],
              },
          ]);
        }
        routes.add((args['sourceId'], args['path']));
        return frame({
          if (args['path']!.endsWith('/reviews'))
            'items': [
              {'id': 'r', 'text': '书评'},
            ]
          else
            'url': 'https://example.com/audio.m4a',
        });
      },
    );
    addTearDown(registry.dispose);
    await registry.load();
    final reviews = registry.source('example').optional;
    expect(reviews.supports(NovelCapability.bookReviews), isTrue);
    expect(reviews.supports(NovelCapability.commentReplies), isFalse);
    expect(reviews.audioSession('42', const []), isNull);
    expect((await reviews.bookReviews('42')).comments.single.text, '书评');

    final chapters = [Chapter(itemId: '9', title: '第一章', volumeName: '')];
    final first = registry
        .source('audio_a')
        .optional
        .audioSession('42', chapters)!;
    final second = registry
        .source('audio_b')
        .optional
        .audioSession('42', chapters)!;
    expect(first.bookId, isNot(second.bookId));
    expect(first.chapters.single.itemId, isNot(second.chapters.single.itemId));
    expect(
      await first.api.audioSource(
        first.chapters.single.itemId,
        bookId: first.bookId,
      ),
      isA<AudioSource>(),
    );
    expect(routes, [
      ('example', '/v1/books/42/reviews'),
      ('audio_a', '/v1/books/42/chapters/9/audio'),
    ]);
  });

  test(
    'ZIP sources preserve book and chapter identity across protocols',
    () async {
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, args, archive) async {
          if (action == 'list') return metadata([package('example', '1.0.0')]);
          return frame(switch (args['path']) {
            '/v1/search' => {
              'items': [
                {'bookId': '42', 'title': '查询结果'},
              ],
            },
            '/v1/books/42' => {
              'bookId': '42',
              'title': '插件标题',
              'author': '插件作者',
            },
            '/v1/books/42/chapters' => {
              'items': [
                {'chapterId': '9', 'title': '章节', 'volumeName': '第一卷'},
              ],
            },
            '/v1/books/42/chapters/9' => {
              'blocks': [
                {'type': 'paragraph', 'text': '插件正文'},
              ],
            },
            _ => throw StateError('${args['path']}'),
          });
        },
      );
      addTearDown(registry.dispose);
      await registry.load();
      final source = registry.source('example');
      expect((await source.search('查询')).items.single.source, 'example');
      final detail = await source.detail('42');
      expect(detail.title, '插件标题');
      expect(detail.author.name, '插件作者');
      final chapters = await source.volumes('42');
      expect(chapters.single.single.volumeName, '第一卷');
      expect(
        (await source.chapter('42', chapters.single.single)).toCacheText(),
        contains('插件正文'),
      );
      expect(source.fullApi, isNull);
      expect(
        novelBookCacheId('example', '42'),
        isNot(novelBookCacheId('fanqie', '42')),
      );
    },
  );

  test(
    'higher ZIP version replaces the source, including outstanding native requests',
    () async {
      final started = Completer<void>();
      final pending = Completer<Uint8List>();
      final folder = Directory.systemTemp.createTempSync('novel-zip-test-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/plugin.zip')
        ..writeAsBytesSync([1, 2, 3]);
      final calls = <Map<String, String>>[];
      var version = '1.0.5';
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, args, archive) async {
          if (action == 'list') return metadata([package('fanqie', version)]);
          if (action == 'install') {
            expect(archive, [1, 2, 3]);
            expect(args['fingerprint'], 'known-file');
            version = '1.0.6';
            return metadata(true);
          }
          calls.add(args);
          if (args['path'] == '/api/v1/books/42/detail') {
            started.complete();
            return pending.future;
          }
          return frame({'code': 0, 'data': {}});
        },
      );
      addTearDown(registry.dispose);
      await registry.load();
      final old = registry.fanqieApi!;
      await old.commentReplies('42', '9', groupId: '42');
      expect(calls.single['method'], 'POST');
      final failure = expectLater(old.detail('42'), throwsStateError);
      await started.future;
      await registry.installZip(file.path, 'known-file');
      expect(registry.fanqieApi, isNot(same(old)));
      await failure;
      pending.complete(frame({}));
    },
  );

  test(
    'legacy publisher stays inactive through a failed replacement',
    () async {
      final folder = Directory.systemTemp.createTempSync(
        'novel-zip-reset-test-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/plugin.zip')
        ..writeAsBytesSync([1, 2, 3]);
      var legacy = true;
      final registry = NovelPluginRegistry(
        supportsZipPackages: true,
        bridge: (action, args, archive) async {
          if (action == 'list') {
            return metadata([
              package('fanqie', legacy ? '1.0.2' : '1.0.5', legacy: legacy),
            ]);
          }
          if (action == 'inspect') {
            return metadata({'fingerprint': 'zip', 'resetPublisher': 'old'});
          }
          if (args['resetPublisher'] != 'old') {
            throw const FormatException('确认重置');
          }
          legacy = false;
          return metadata(true);
        },
      );
      addTearDown(registry.dispose);
      await registry.load();
      expect(registry.legacyPlugins.single.version, '1.0.2');
      expect(registry.fanqieApi, isNull);
      final inspected = await registry.inspectZip(file.path);
      await expectLater(
        registry.installZip(file.path, 'zip'),
        throwsFormatException,
      );
      expect(registry.legacyPlugins.single.version, '1.0.2');
      await registry.installZip(
        file.path,
        'zip',
        resetPublisher: inspected['resetPublisher'] as String,
      );
      expect(registry.plugins.single.version, '1.0.5');
      expect(registry.legacyPlugins, isEmpty);
    },
  );
}

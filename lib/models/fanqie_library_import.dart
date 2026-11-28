/// Credential-free projection shared by Android import and the local converter.
/// Only explicit novel records enter the reader; audio/comic identities differ.
library;

import 'media_item.dart';

bool resolveFanqieChapter(Map<String, dynamic> record, List<Chapter> chapters) {
  final chapterId = record['chapterId'];
  if (chapterId == null) return false;
  final index = chapters.indexWhere((c) => c.itemId == chapterId);
  if (index < 0) return false;
  record['episode'] = index;
  record['progress'] = index / chapters.length;
  record['ep'] = '第 ${index + 1} 章';
  return true;
}

class FanqieLibraryImport {
  final Map<String, Map<String, dynamic>> _books = {};
  final Map<String, Map<String, dynamic>> _positions = {};
  final Set<String> _shelfIds = {};
  final Set<String> _deletedShelfIds = {};
  final Set<String> _shelfIdsWithoutType = {};
  final Set<String> _shelfInfoIdsWithInferredNovelType = {};
  bool _hasShelfSource = false;
  bool _shelfSourceFailed = false;
  bool _shelfSourceIncomplete = false;
  bool _shelfInfoComplete = false;
  int _deletedShelfRecords = 0;
  int _camelCaseShelfRecords = 0;
  int _shelfInfoCamelCaseRecords = 0;
  int received = 0;
  int failed = 0;
  int incomplete = 0;
  int skipped = 0;

  static bool _affectsShelfCoverage(Object? resource) =>
      resource == 'folder_list' ||
      resource == 'folder_detail' ||
      resource == 'shelf_list' ||
      resource == 'shelf_info';

  static bool _isShelfRecordResource(Object? resource) =>
      resource == 'shelf_list' ||
      resource == 'shelf_info' ||
      resource == 'folder_detail';

  static const _shelfSnapshotKeys = {
    'book_shelf_info',
    'bookShelfInfo',
    'book_shelf_info_all',
    'bookShelfInfoAll',
    'book_list',
    'bookList',
  };

  static bool _hasRecognizedShelfData(dynamic data) {
    if (data is List) return true;
    if (data is! Map) return false;
    return _shelfSnapshotKeys.any((key) => data[key] is List);
  }

  static bool _isDeleted(Map raw) =>
      raw['is_delete'] == true || raw['is_delete'] == 1;

  void addSource(Map<String, dynamic> source) {
    final resource = source['resource'];
    final status = source['status'];
    if (status == 'received') {
      received++;
    } else if (status == 'incomplete') {
      // 采集层已判定这一来源不完整（分页未走完、上游声明快照不全）。已收到
      // 的记录仍然可用，但整次导入必须显示为部分导入，不能当成完整书架。
      incomplete++;
      if (_affectsShelfCoverage(resource)) _shelfSourceIncomplete = true;
    } else {
      failed++;
      if (_affectsShelfCoverage(resource)) _shelfSourceFailed = true;
      return;
    }
    final payload = source['payload'];
    if (payload is! Map) {
      if (_affectsShelfCoverage(resource)) _shelfSourceFailed = true;
      return;
    }
    if (!const [0, '0'].contains(payload['code'])) {
      if (_affectsShelfCoverage(resource)) _shelfSourceFailed = true;
      return;
    }
    final data = payload['data'];
    if (resource == 'folder_list') return;
    if (resource == 'shelf_info' &&
        status == 'received' &&
        _hasRecognizedShelfData(data)) {
      _shelfInfoComplete = true;
    }
    if (resource == 'book_detail') {
      if (data is Map) _metadata(data);
      return;
    }
    if (resource == 'history' && data is Map) {
      for (final raw in data['data_list'] as List? ?? const []) {
        if (raw is! Map) continue;
        if (!_novel(raw) || _isDeleted(raw)) {
          skipped++;
          continue;
        }
        final record = _include(raw);
        if (record == null) continue;
        final time = _time(raw);
        if (time > (record['time'] as int)) record['time'] = time;
      }
    } else if (_isShelfRecordResource(resource)) {
      _hasShelfSource = true;
      void visit(dynamic value) {
        if (value is List) {
          for (final item in value) {
            visit(item);
          }
        } else if (value is Map) {
          final id = _id(value['book_id_str']) ?? _id(value['book_id']);
          if (value.containsKey('book_type') && value['book_type'] != null) {
            if (!_novel(value) || _isDeleted(value)) {
              skipped++;
              if (_novel(value) && _isDeleted(value) && id != null) {
                _deletedShelfIds.add(id);
                _shelfIds.remove(id);
                _deletedShelfRecords++;
              }
              return;
            }
            // A book record's nested maps/lists are its own fields
            // (author info, nested recommendations), not more shelf
            // entries. Recursing into them would import recommendations
            // and related books as if the user had shelved them.
            final record = _include(value);
            if (record != null) {
              final id = record['id'] as String;
              // 最后一次观察优先：先读到删除标记、随后在文件夹里又读到仍在
              // 书架的书，不能被前一个标记永久排除。
              _deletedShelfIds.remove(id);
              _shelfIds.add(id);
              final time = _time(value);
              if (time > (record['time'] as int)) record['time'] = time;
            }
            return;
          }
          // 带作品 ID 却没有 book_type：上游确实给了这本书，但判不出它是不是
          // 小说。`bookshelf/info` 的标准书目条目会省略该字段；采集层的类型
          // 缺省也是 0，这里按同样规则归一，并保留推断数量供界面披露。
          if (id != null) {
            if (resource == 'shelf_info') {
              if (_isDeleted(value)) {
                skipped++;
                _deletedShelfIds.add(id);
                _shelfIds.remove(id);
                _deletedShelfRecords++;
                return;
              }
              _shelfInfoIdsWithInferredNovelType.add(id);
              final record = _include(value);
              if (record != null) {
                _deletedShelfIds.remove(id);
                _shelfIds.add(id);
                final time = _time(value);
                if (time > (record['time'] as int)) record['time'] = time;
              }
              return;
            }
            _shelfIdsWithoutType.add(id);
          } else if (value.containsKey('bookId') ||
              value.containsKey('bookType')) {
            // 整条记录都不在已知字段名里：它不会进书架，也不能进历史，
            // 至少要把条数告诉用户。
            _camelCaseShelfRecords++;
            if (resource == 'shelf_info') {
              _shelfInfoCamelCaseRecords++;
            }
          }
          for (final entry in value.entries) {
            final key = entry.key.toString().toLowerCase();
            if (key.contains('recommend') || key.contains('delete')) {
              continue;
            }
            final child = entry.value;
            if (child is Map || child is List) visit(child);
          }
        }
      }

      visit(data);
    } else if ((resource == 'progress_list' || resource == 'progress_batch') &&
        data is List) {
      for (final raw in data) {
        if (raw is! Map || !_novel(raw)) continue;
        final record = _include(raw);
        final chapter = _id(raw['item_id']);
        if (record == null || chapter == null) continue;
        final id = record['id'] as String;
        final time = _time(raw);
        final previous = _positions[id];
        if (previous != null && time < (previous['time'] as int)) continue;
        _positions[id] = {
          'time': time,
          'chapterId': chapter,
          // Preserve evidence, never reinterpret paragraph offsets as UTF-16.
          'officialAnchor': {
            for (final key in [
              'order',
              'real_chapter_order',
              'paragraph_id',
              'paragraph_offset',
              'item_progress_rate',
              'progress_rate',
            ])
              if (raw[key] is num || raw[key] is String) key: raw[key],
          },
        };
      }
    }
  }

  bool _novel(Map raw) => raw['book_type']?.toString() == '0';

  Map<String, dynamic>? _include(Map raw) {
    final id = _id(raw['book_id_str']) ?? _id(raw['book_id']);
    if (id == null) return null;
    final record = _books.putIfAbsent(
      id,
      () => {
        'id': id,
        'bookId': id,
        'kind': 'book',
        'title': '',
        'cover': '',
        'author': '',
        'time': 0,
        'fanqieImported': true,
      },
    );
    _fill(record, raw);
    return record;
  }

  void _metadata(Map raw) {
    final id = _id(raw['book_id']);
    // Metadata alone is not proof of a shelf/history relationship.
    if (id == null) return;
    final record = _books[id];
    if (record != null) _fill(record, raw);
  }

  void _fill(Map<String, dynamic> record, Map raw) {
    for (final field in {
      'title': 'book_name',
      'cover': 'thumb_url',
      'author': 'author',
    }.entries) {
      final value = raw[field.value];
      if (value is String && value.isNotEmpty && value.length <= 8192) {
        if (field.key == 'cover') {
          final uri = Uri.tryParse(value);
          if (uri == null ||
              !const ['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            continue;
          }
        }
        record[field.key] = value;
      }
    }
  }

  Set<String> get shelfIds => Set<String>.unmodifiable(_shelfIds);

  bool get hasShelfSource => _hasShelfSource;

  /// `shelf_info` 是官方完整书架名单；它成功返回标准结构后，`shelf_list`
  /// 的增量残缺或文件夹遍历失败不应再否定已经完整的书架覆盖。
  bool get shelfInfoComplete => _shelfInfoComplete;

  bool get shelfSourceFailed => _shelfSourceFailed && !_shelfInfoComplete;

  /// 书架来源有一次没走完（分页中断或上游声明快照不完整）。
  bool get shelfSourceIncomplete =>
      _shelfSourceIncomplete && !_shelfInfoComplete;

  /// 书架响应里带作品 ID、却没有可识别的类型字段，因此没有计入书架的数量。
  /// 这个数字是「导入变少」最直接的线索，必须能被用户看到。
  int get shelfRecordsMissingType =>
      _shelfInfoComplete ? 0 : _shelfIdsWithoutType.length;

  /// `shelf_info` 中省略 `book_type`、按小说缺省值计入书架的唯一作品数。
  int get shelfInfoInferredNovelCount =>
      _shelfInfoIdsWithInferredNovelType.length;

  /// 书架来源里带删除标记、被排除在书架之外的作品数。
  int get deletedShelfRecords => _deletedShelfRecords;

  /// 书架响应里整条记录都不在已知字段名下（如 bookId / bookType）的条数。
  int get unrecognizedShelfRecords =>
      _shelfInfoComplete ? _shelfInfoCamelCaseRecords : _camelCaseShelfRecords;

  /// 书架数据是否可以作为完整结果呈现。
  bool get shelfSourceComplete =>
      _hasShelfSource && !shelfSourceFailed && !shelfSourceIncomplete;

  List<Map<String, dynamic>> get shelfRecords => [
    for (final record in records)
      if (_shelfIds.contains(record['id'])) record,
  ];

  List<Map<String, dynamic>> get records => [
    for (final entry in _books.entries)
      {
        ...entry.value,
        if (_positions[entry.key] case final position?) ...{
          'chapterId': position['chapterId'],
          'officialAnchor': position['officialAnchor'],
          'time': (entry.value['time'] as int) > (position['time'] as int)
              ? entry.value['time']
              : position['time'],
        },
      },
  ];

  static int _time(Map raw) {
    final ms = int.tryParse('${raw['read_timestamp_ms']}') ?? 0;
    final seconds = int.tryParse('${raw['read_timestamp']}') ?? 0;
    final time = ms > 0 ? ms : seconds * 1000;
    return time >= 0 && time <= 8640000000000000 ? time : 0;
  }

  static String? _id(dynamic value) {
    final text = value?.toString() ?? '';
    return RegExp(r'^[0-9]{1,20}$').hasMatch(text) &&
            !RegExp(r'^0+$').hasMatch(text)
        ? text
        : null;
  }
}

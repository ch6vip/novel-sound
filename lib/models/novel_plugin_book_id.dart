import 'shelf_identity.dart';

String novelBookCacheId(String source, String bookId) =>
    source == ShelfIdentity.fanqie ? bookId : novelPluginBookId(source, bookId);

String novelPluginBookId(String source, String bookId) =>
    'plugin:$source:$bookId';

({String source, String bookId})? parseNovelPluginBookId(String key) {
  final parts = key.split(':');
  if (parts.length != 3 ||
      parts.first != 'plugin' ||
      !ShelfIdentity.isValidSource(parts[1]) ||
      !ShelfIdentity.isValidContentId(parts[2])) {
    return null;
  }
  return (source: parts[1], bookId: parts[2]);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/search_filters.dart';

MediaItem _book({
  String title = '书',
  List<String> categories = const [],
  int status = -1,
  int words = 0,
}) => MediaItem(
  id: title,
  kind: 'book',
  title: title,
  cover: '',
  author: '作者',
  badge: '',
  ep: '',
  categories: categories,
  creationStatus: status,
  wordNumber: words,
);

void main() {
  test('默认放行一切', () {
    const filters = SearchFilters();
    expect(filters.isActive, isFalse);
    expect(filters.matches(_book(status: 1, words: 10)), isTrue);
  });

  test('按连载状态过滤', () {
    const filters = SearchFilters(status: 0);
    expect(filters.matches(_book(status: 0)), isTrue);
    expect(filters.matches(_book(status: 1)), isFalse);
    expect(filters.matches(_book(status: 4)), isFalse);
    expect(filters.matches(_book(status: -1)), isFalse);
  });

  test('按字数档位过滤', () {
    expect(const SearchFilters(wordCount: 1).matches(_book(words: 200000)), isTrue);
    expect(const SearchFilters(wordCount: 1).matches(_book(words: 400000)), isFalse);
    expect(const SearchFilters(wordCount: 2).matches(_book(words: 400000)), isTrue);
    expect(const SearchFilters(wordCount: 3).matches(_book(words: 2000000)), isTrue);
    expect(const SearchFilters(wordCount: 4).matches(_book(words: 3000000)), isTrue);
    expect(const SearchFilters(wordCount: 4).matches(_book(words: 2999999)), isFalse);
    expect(const SearchFilters(wordCount: 1).matches(_book(words: 0)), isFalse);
  });

  test('分类词优先匹配分类标签', () {
    const filters = SearchFilters(tag: '都市');
    expect(filters.matches(_book(categories: const ['都市', '爽文'])), isTrue);
    expect(filters.matches(_book(categories: const ['玄幻'])), isFalse);
    // 书名兜底：分类标签缺失时仍能命中带该词的作品。
    expect(filters.matches(_book(title: '都市之巅')), isTrue);
  });

  test('clearTag 只清分类，保留其余条件', () {
    const filters = SearchFilters(status: 0, wordCount: 4, tag: '都市');
    final cleared = filters.copyWith(clearTag: true);
    expect(cleared.tag, isNull);
    expect(cleared.status, 0);
    expect(cleared.wordCount, 4);
  });
}

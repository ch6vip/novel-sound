import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/search/search_discovery.dart';
import 'package:fqapp/widgets/search/search_media_tile.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// Finders for the Wenku8 search page. Tests keep their behavioural
/// assertions; only how a control is located moved with the ported UI.

/// One category or source segment ('综合' … '听书', '书旗').
Finder searchSegment(String label) => find.descendant(
  of: find.byKey(const Key('search-category-tabs')),
  matching: find.text(label),
);

/// A rendered result, in either list or grid layout.
Finder get searchResultTiles => find.byWidgetPredicate(
  (widget) => widget is SearchNovelRow || widget is SearchBookGridTile,
);

/// Grid tiles only (the cover layout).
Finder get searchGridTiles => find.byType(SearchBookGridTile);

/// Content kinds of the rendered results, top to bottom.
List<String> searchVisibleKinds(WidgetTester tester) => [
  for (final element in searchResultTiles.evaluate())
    switch (element.widget) {
      final SearchNovelRow row => row.item.kind,
      final SearchBookGridTile tile => tile.item.kind,
      _ => throw StateError('unexpected tile'),
    },
];

/// Upstream `FeedFooter` end marker.
const searchEndOfResults = '已经到底了';

/// Upstream `FeedFooter` continuation button label.
const searchLoadMore = '加载更多';

/// Upstream `FeedFooter` retry button for a failed page.
const searchRetry = '重试';

/// Recent-searches heading (shown only when history exists, as upstream).
const searchRecentHeading = '最近搜索';

/// The vertical results list (not the segmented tab row).
Finder get searchResultsScrollable => find
    .descendant(
      of: find.byType(BookCollectionView),
      matching: find.byType(Scrollable),
    )
    .first;

/// The empty-query discovery screen (recent searches and hot list).
Finder get searchDiscoveryScreen => find.byType(SearchDiscoveryView);

/// The first-page skeleton shown while a category loads.
Finder get searchFirstPageSkeleton => find.byType(SearchSkeleton);

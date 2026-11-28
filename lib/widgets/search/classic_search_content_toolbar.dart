import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// Searches use the same result controls across all installed sources.
class ClassicSearchContentToolbar extends StatelessWidget {
  const ClassicSearchContentToolbar({
    super.key,
    required this.listView,
    required this.onToggleLayout,
    this.showFilterHint = false,
    this.filters,
  });

  static const double height = 44;

  final bool listView;
  final VoidCallback onToggleLayout;
  final bool showFilterHint;
  final Widget? filters;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 0, homeGutter - 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: filters ?? const SizedBox.shrink()),
              IconButton(
                key: const Key('search-layout-toggle'),
                tooltip: listView ? '切换为封面视图' : '切换为无封面列表',
                onPressed: onToggleLayout,
                padding: EdgeInsets.zero,
                iconSize: 19,
                color: palette.ink,
                style: IconButton.styleFrom(
                  minimumSize: const Size(height, height),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  listView ? LucideIcons.layout_grid : LucideIcons.list,
                ),
              ),
            ],
          ),
          if (showFilterHint)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '筛选已加载结果，可继续加载更多。',
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// 按作品 ID 查找命中后的提示行；只在结果态出现，随内容一起滚动。
class ClassicSearchIdLookupHint extends StatelessWidget {
  /// 「按关键词搜索」要用输入框里的当前文字，调用方直接传入当前文本。
  final VoidCallback onKeywordSearch;

  const ClassicSearchIdLookupHint({super.key, required this.onKeywordSearch});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 2, homeGutter, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '按作品 ID 查找',
              style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
            ),
          ),
          TextButton(
            onPressed: onKeywordSearch,
            style: TextButton.styleFrom(
              foregroundColor: palette.accentText,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              '按关键词搜索',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

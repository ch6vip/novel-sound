import 'dart:async';
import 'dart:convert';

import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../services/app_style_tokens.dart';
import '../services/book_open_preferences.dart';
import '../services/home_continue_preferences.dart';
import '../services/home_feed_cache.dart';
import '../services/library_store.dart';
import '../services/novel_plugins.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/classic_home_skeleton.dart';
import '../widgets/home/home_archive.dart' show homeCardTitleSize;
import '../widgets/home/home_cell_blocks.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_masthead.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_reading_row.dart';
import '../widgets/home/home_sheet.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/home/home_skeleton.dart';
import '../widgets/home/home_tab_bar.dart';
import '../widgets/home/ugc_story_feed.dart';
import '../widgets/settings/settings_widgets.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'novel_plugins_page.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'ugc_story_provider.dart';

class PluginHomePage extends StatefulWidget {
  const PluginHomePage({super.key, this.registry, this.scrollController});

  final NovelPluginRegistry? registry;
  final ScrollController? scrollController;

  @override
  State<PluginHomePage> createState() => _PluginHomePageState();
}

class _PluginHomePageState extends State<PluginHomePage> {
  static const _sourcePreference = 'home.novelSource';
  static const _channelPreference = 'home.novelChannels.';
  late final _registry = widget.registry ?? NovelPluginRegistry.instance;
  final _feeds = <(NovelPlugin, String), _ChannelFeed>{};
  final _lastChannels = <String, String>{};
  final _scrolls = PageStorageBucket();
  final _storyScroll = ScrollController();
  SharedPreferences? _preferences;
  NovelPlugin? _plugin;
  String? _channel;
  String? _error;
  bool _ready = false;
  Listenable? _history;

  NovelSourceCapabilities? get _capabilities {
    final plugin = _plugin;
    return plugin == null ? null : _registry.source(plugin.id).optional;
  }

  @override
  void initState() {
    super.initState();
    _registry.addListener(_packagesChanged);
    final library = LibraryStore.instance;
    if (library.isInitialized) {
      _history = library.historyListenable..addListener(_historyChanged);
    }
    HomeContinuePreferences.instance.dismissedId.addListener(_historyChanged);
    unawaited(HomeContinuePreferences.instance.load());
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      await _registry.load();
    } catch (error) {
      _error = userFacingError(error);
    }
    if (!mounted) return;
    _ready = true;
    _packagesChanged();
  }

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _registry.removeListener(_packagesChanged);
    _history?.removeListener(_historyChanged);
    _storyScroll.dispose();
    HomeContinuePreferences.instance.dismissedId.removeListener(
      _historyChanged,
    );
    super.dispose();
  }

  void _packagesChanged() {
    if (!_ready || !mounted) return;
    final previous = _plugin;
    _feeds.removeWhere(
      (key, _) => !identical(_registry.plugin(key.$1.id), key.$1),
    );
    final preferred =
        previous?.id ?? _preferences?.getString(_sourcePreference);
    final selected =
        (preferred == null ? null : _registry.plugin(preferred)) ??
        _registry.plugins.firstOrNull;
    _selectSource(selected);
  }

  void _selectSource(NovelPlugin? plugin) {
    if (_plugin != plugin) {
      if (_plugin case final previous?) {
        if (_channel case final previousChannel?) {
          _lastChannels[previous.id] = previousChannel;
          final feed = _feeds[(previous, previousChannel)];
          if (feed != null && feed.loading) {
            feed.generation++;
            feed.loading = false;
          }
        }
      }
    }
    setState(() {
      _plugin = plugin;
      final channels = _visibleChannels();
      final previousChannel = plugin == null ? null : _lastChannels[plugin.id];
      _channel = channels.any((entry) => entry.id == previousChannel)
          ? previousChannel
          : channels.firstOrNull?.id;
      if (plugin != null && _channel != null) {
        _lastChannels[plugin.id] = _channel!;
      }
    });
    if (plugin != null) {
      unawaited(_preferences?.setString(_sourcePreference, plugin.id));
    }
    _ensureFeed();
  }

  List<({NovelHomeChannel channel, bool visible})> _configuredChannels() {
    final sourceId = _plugin?.id;
    final available = _capabilities?.channels ?? const [];
    final remaining = {for (final channel in available) channel.id: channel};
    final result = <({NovelHomeChannel channel, bool visible})>[];
    final stored = sourceId == null
        ? null
        : _preferences?.getString('$_channelPreference$sourceId');
    if (stored != null) {
      try {
        final entries = jsonDecode(stored) as List;
        for (final entry in entries) {
          if (entry is! List || entry.length != 2) continue;
          final channel = remaining.remove(entry.first);
          if (channel != null) {
            result.add((channel: channel, visible: entry.last != false));
          }
        }
      } on FormatException {
        // Ignore old or damaged preferences.
      } on TypeError {
        // Ignore values saved in an incompatible format.
      }
    }
    result.addAll(
      remaining.values.map((item) => (channel: item, visible: true)),
    );
    return result;
  }

  List<NovelHomeChannel> _visibleChannels() => [
    for (final item in _configuredChannels())
      if (item.visible) item.channel,
  ];

  void _selectChannel(String id) {
    if (_channel == id) return;
    setState(() {
      _channel = id;
      _lastChannels[_plugin!.id] = id;
    });
    _ensureFeed();
  }

  void _ensureFeed() {
    final plugin = _plugin;
    final channel = _channel;
    if (plugin == null || channel == null) return;
    if (channel == 'stories' && _capabilities?.storyFeedApi != null) return;
    final feed = _feedFor(plugin, channel);
    if (!feed.loaded && !feed.loading) unawaited(_load());
  }

  _ChannelFeed _feedFor(NovelPlugin plugin, String channel) =>
      _feeds.putIfAbsent((plugin, channel), () {
        final feed = _ChannelFeed();
        final cached = HomeFeedCache.instance.loadPlugin(
          plugin.id,
          plugin.publisher,
          channel,
        );
        if (cached != null) {
          feed.cells = cached.cells;
          for (final item in cached.items) {
            feed.items[(item.kind, item.id)] = item;
          }
        }
        return feed;
      });

  Future<void> _load({bool more = false, bool refresh = false}) async {
    final plugin = _plugin;
    final channel = _channel;
    final capabilities = _capabilities;
    if (plugin == null || channel == null || capabilities == null) return;
    final feed = _feedFor(plugin, channel);
    if ((!refresh && feed.loading) || (more && feed.cursor == null)) return;
    final generation = ++feed.generation;
    setState(() {
      feed.loading = true;
      feed.error = null;
    });
    try {
      final page = await capabilities.home(
        channel,
        cursor: more ? feed.cursor : null,
      );
      if (!mounted || !_current(plugin, channel, feed, generation)) return;
      setState(() {
        if (!more) {
          feed.items.clear();
          feed.cursors.clear();
          feed.cells = page.cells;
        }
        for (final item in page.items) {
          feed.items.putIfAbsent((item.kind, item.id), () => item);
        }
        final cursor = page.nextCursor;
        feed.cursor = cursor != null && feed.cursors.add(cursor)
            ? cursor
            : null;
        feed.loaded = true;
      });
      if (!more) {
        unawaited(
          HomeFeedCache.instance.savePlugin(
            plugin.id,
            plugin.publisher,
            channel,
            feed.items.values.toList(),
            cells: feed.cells,
          ),
        );
      }
    } catch (error) {
      if (!mounted || !_current(plugin, channel, feed, generation)) return;
      setState(() {
        feed.error = userFacingError(
          error,
        ).replaceFirst(RegExp(r'后重试$|，请(?:稍后)?重试$'), '');
        feed.retryMore = more;
      });
    } finally {
      if (mounted && _current(plugin, channel, feed, generation)) {
        setState(() => feed.loading = false);
      }
    }
  }

  bool _current(
    NovelPlugin plugin,
    String channel,
    _ChannelFeed feed,
    int generation,
  ) =>
      identical(_feeds[(plugin, channel)], feed) &&
      feed.generation == generation;

  Widget _sourceButton(HomePalette palette) {
    final plugin = _plugin;
    final name = plugin?.name ?? '导入插件';
    final style = TextStyle(
      inherit: false,
      color: palette.ink,
      fontSize: 13,
      fontWeight: MediaQuery.boldTextOf(context)
          ? FontWeight.bold
          : FontWeight.w600,
    );
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    double measure(String text) {
      painter
        ..text = TextSpan(text: text, style: style)
        ..layout();
      return painter.width;
    }

    final labelWidth = measure('番茄');
    final nameWidth = measure(name);
    painter.dispose();
    final animate =
        nameWidth > labelWidth &&
        !palette.eink &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    final label = Text(
      name,
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: animate ? TextOverflow.clip : TextOverflow.ellipsis,
    );
    final pill = Container(
      height: HomeHero.searchBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.searchBar,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: labelWidth,
            child: animate
                ? Semantics(
                    label: name,
                    excludeSemantics: true,
                    child: _ScrollingSourceName(
                      key: ValueKey((name, labelWidth, nameWidth)),
                      nameWidth: nameWidth,
                      distance: nameWidth - labelWidth,
                      child: label,
                    ),
                  )
                : label,
          ),
          const SizedBox(width: 3),
          Icon(
            plugin == null ? LucideIcons.plus : LucideIcons.chevron_down,
            size: 15,
            color: palette.ink,
          ),
        ],
      ),
    );
    if (plugin == null) {
      return HomePressable(
        key: const Key('home_plugin_source'),
        onTap: () => openNovelPlugins(context),
        borderRadius: BorderRadius.circular(20),
        child: pill,
      );
    }
    return PopupMenuButton<String>(
      key: const Key('home_plugin_source'),
      tooltip: nameWidth > labelWidth ? '切换首页书源 · $name' : '切换首页书源',
      position: PopupMenuPosition.under,
      color: palette.surface,
      onSelected: (id) {
        if (_registry.plugin(id) case final selection?) {
          _selectSource(selection);
        }
      },
      itemBuilder: (_) => [
        for (final candidate in _registry.plugins)
          CheckedPopupMenuItem(
            value: candidate.id,
            checked: plugin.id == candidate.id,
            child: Text(candidate.name),
          ),
        for (final candidate in _registry.legacyPlugins)
          PopupMenuItem<String>(
            enabled: false,
            child: Text('${candidate.name} · 待更新'),
          ),
      ],
      child: pill,
    );
  }

  Future<void> _configureChannels() async {
    final plugin = _plugin;
    if (plugin == null) return;
    final defaults = _capabilities!.channels;
    final entries = _configuredChannels();
    final result =
        await showHomeSheet<List<({NovelHomeChannel channel, bool visible})>>(
          context: context,
          title: '管理栏目',
          children: [
            StatefulBuilder(
              builder: (context, update) => Column(
                children: [
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: entries.length,
                    onReorderItem: (oldIndex, newIndex) => update(() {
                      entries.insert(newIndex, entries.removeAt(oldIndex));
                    }),
                    itemBuilder: (context, index) {
                      final item = entries[index];
                      return ListTile(
                        key: ValueKey(item.channel.id),
                        leading: ReorderableDragStartListener(
                          index: index,
                          child: const Icon(LucideIcons.grip_vertical),
                        ),
                        title: Text(item.channel.title),
                        trailing: SettingsSwitch(
                          value: item.visible,
                          onChanged: (value) => update(() {
                            entries[index] = (
                              channel: item.channel,
                              visible: value,
                            );
                          }),
                        ),
                      );
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => update(() {
                          entries
                            ..clear()
                            ..addAll(
                              defaults.map(
                                (channel) => (channel: channel, visible: true),
                              ),
                            );
                        }),
                        child: const Text('恢复默认'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, entries),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
    if (result == null || !mounted || !identical(plugin, _plugin)) return;
    await _preferences?.setString(
      '$_channelPreference${plugin.id}',
      jsonEncode([
        for (final entry in result) [entry.channel.id, entry.visible],
      ]),
    );
    if (mounted && identical(plugin, _plugin)) _selectSource(plugin);
  }

  void _open(MediaItem item) => unawaited(openBookDetail(context, item));

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final tokens = AppStyleTokens.of(context);
    final classic = tokens.isClassic;
    final capabilities = _capabilities;
    final visible = _visibleChannels();
    final plugin = _plugin;
    final category = capabilities?.supports(NovelCapability.categories) == true
        ? () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => CategoryPage(
                loader: capabilities!.categories,
                sourceId: plugin!.id,
              ),
            ),
          )
        : null;
    void search() => plugin == null
        ? openNovelPlugins(context)
        : openNovelPluginSearch(context, sourceId: plugin.id);
    final rank = capabilities?.supports(NovelCapability.rankings) == true;
    void openRanks() => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankPage(
          catalogLoader: capabilities!.rankCatalog,
          pageLoader: capabilities.rankBoard,
          sourceId: plugin!.id,
        ),
      ),
    );
    final channel = _channel;
    final feed = _feeds[(plugin, channel)];
    final storyApi = channel == 'stories' ? capabilities?.storyFeedApi : null;
    final now = plugin != null && channel == 'recommended'
        ? latestReadingNow(sourceId: plugin.id)
        : null;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (classic)
              HomeHero(
                key: ObjectKey(plugin),
                leading: _sourceButton(palette),
                onSearch: search,
                onCategory: category,
                cueLoader:
                    capabilities?.supports(NovelCapability.searchCue) == true
                    ? capabilities!.searchCue
                    : null,
              )
            else
              HomeMasthead(
                leading: _sourceButton(palette),
                onSearch: search,
                onCategory: category,
              ),
            if (capabilities?.channels.isNotEmpty == true)
              Row(
                children: [
                  if (visible.isEmpty)
                    const Spacer()
                  else
                    Expanded(
                      child: HomeTabBar(
                        categories: [
                          for (final item in visible) HomeCategory(item.title),
                        ],
                        selectedIndex: visible.indexWhere(
                          (item) => item.id == channel,
                        ),
                        onSelect: (index) => _selectChannel(visible[index].id),
                      ),
                    ),
                  IconButton(
                    key: const Key('home_manage_channels'),
                    tooltip: '管理栏目',
                    onPressed: _configureChannels,
                    icon: const Icon(LucideIcons.sliders_horizontal, size: 19),
                  ),
                ],
              ),
            Expanded(
              child: storyApi != null
                  ? ProviderScope(
                      key: ObjectKey(plugin),
                      overrides: [
                        ugcStoriesProvider.overrideWith(
                          () => UgcStoriesNotifier(api: storyApi),
                        ),
                      ],
                      child: UgcStoryFeed(
                        active: true,
                        scrollController:
                            widget.scrollController ?? _storyScroll,
                        api: storyApi,
                      ),
                    )
                  : !_ready ||
                        (feed?.loading == true &&
                            feed?.loaded != true &&
                            feed!.items.isEmpty)
                  ? SingleChildScrollView(
                      child: classic
                          ? const ClassicHomeSkeleton()
                          : const HomeSkeleton(),
                    )
                  : feed == null
                  ? Center(
                      child: Text(
                        _error ??
                            (plugin == null
                                ? '导入插件后浏览首页'
                                : capabilities!.channels.isEmpty
                                ? '此书源支持搜索'
                                : '已隐藏全部栏目'),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth - homeGutter * 2;
                        return RefreshIndicator(
                          onRefresh: () => _load(refresh: true),
                          child: PageStorage(
                            bucket: _scrolls,
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                if (notification.metrics.extentAfter < 480 &&
                                    feed.error == null &&
                                    feed.cursor != null) {
                                  unawaited(_load(more: true));
                                }
                                return false;
                              },
                              child: CustomScrollView(
                                key: PageStorageKey((plugin!.id, channel)),
                                controller: widget.scrollController,
                                physics: const AlwaysScrollableScrollPhysics(),
                                slivers: [
                                  if (now != null &&
                                      !HomeContinuePreferences.instance
                                          .isDismissed(now.item))
                                    SliverToBoxAdapter(
                                      child: HomeContinueRow(
                                        now: now,
                                        onOpen: () => unawaited(
                                          openBookDetail(
                                            context,
                                            now.item,
                                            entry: BookOpenEntry.shelf,
                                          ),
                                        ),
                                        onDismiss: () => HomeContinuePreferences
                                            .instance
                                            .dismiss(now.item),
                                      ),
                                    ),
                                  if (rank && channel == 'recommended')
                                    for (final cell in feed.cells.where(
                                      (cell) =>
                                          cell.showType ==
                                          kHomeCellRankShowType,
                                    ))
                                      SliverToBoxAdapter(
                                        child: HomeRankCell(
                                          cell: cell,
                                          onOpen: (item) => _open(
                                            item.copyWith(source: plugin.id),
                                          ),
                                          onMore: openRanks,
                                          loadBoard: (id, algo) async => [
                                            for (final entry
                                                in (await capabilities!
                                                        .rankBoard(
                                                          rankId: id,
                                                          algo: algo,
                                                        ))
                                                    .entries)
                                              entry.toMediaItem().copyWith(
                                                source: plugin.id,
                                              ),
                                          ],
                                        ),
                                      ),
                                  if (rank &&
                                      channel == 'recommended' &&
                                      !feed.cells.any(
                                        (cell) =>
                                            cell.showType ==
                                            kHomeCellRankShowType,
                                      ))
                                    SliverToBoxAdapter(
                                      child: ListTile(
                                        title: const Text('排行榜'),
                                        trailing: const Icon(
                                          LucideIcons.chevron_right,
                                        ),
                                        onTap: openRanks,
                                      ),
                                    ),
                                  if (feed.items.isNotEmpty &&
                                      channel == 'recommended')
                                    const SliverToBoxAdapter(
                                      child: HomeSectionHeader(title: '为你推荐'),
                                    ),
                                  if (feed.items.isNotEmpty)
                                    SliverPadding(
                                      padding: const EdgeInsets.fromLTRB(
                                        homeGutter,
                                        12,
                                        homeGutter,
                                        0,
                                      ),
                                      sliver: SliverGrid.builder(
                                        gridDelegate: homeShelfDelegate(
                                          context,
                                          width,
                                        ),
                                        itemCount: feed.items.length,
                                        itemBuilder: (_, index) {
                                          final item = feed.items.values
                                              .elementAt(index);
                                          return HomeMediaCard(
                                            item: item,
                                            coverWidth: homeShelfCardWidth(
                                              context,
                                              width,
                                            ),
                                            radius: classic
                                                ? 12
                                                : tokens.coverRadius,
                                            titleSize: classic
                                                ? 15
                                                : homeCardTitleSize,
                                            onTap: () => _open(item),
                                          );
                                        },
                                      ),
                                    )
                                  else if (feed.error == null)
                                    const SliverFillRemaining(
                                      hasScrollBody: false,
                                      child: Center(child: Text('暂无内容')),
                                    ),
                                  if (feed.error case final error?)
                                    SliverToBoxAdapter(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: homeGutter,
                                        ),
                                        child: Wrap(
                                          alignment: WrapAlignment.center,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(error),
                                            TextButton(
                                              onPressed: () =>
                                                  _load(more: feed.retryMore),
                                              child: const Text('重试'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (feed.cursor != null &&
                                      !feed.loading &&
                                      feed.error == null)
                                    SliverToBoxAdapter(
                                      child: Center(
                                        child: TextButton(
                                          onPressed: () => _load(more: true),
                                          child: const Text('加载更多'),
                                        ),
                                      ),
                                    ),
                                  if (feed.loading && feed.loaded)
                                    const SliverToBoxAdapter(
                                      child: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    ),
                                  SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: homeBottomClearance(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrollingSourceName extends StatefulWidget {
  const _ScrollingSourceName({
    super.key,
    required this.nameWidth,
    required this.distance,
    required this.child,
  });

  final double nameWidth;
  final double distance;
  final Widget child;

  @override
  State<_ScrollingSourceName> createState() => _ScrollingSourceNameState();
}

class _ScrollingSourceNameState extends State<_ScrollingSourceName> {
  Timer? _pause;
  bool _showEnd = false;

  @override
  void initState() {
    super.initState();
    _waitAtEdge();
  }

  void _waitAtEdge() {
    _pause = Timer(const Duration(seconds: 1), () {
      setState(() => _showEnd = !_showEnd);
    });
  }

  @override
  void dispose() {
    _pause?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AnimatedPositionedDirectional(
          duration: Duration(milliseconds: (widget.distance * 30).ceil()),
          onEnd: _waitAtEdge,
          start: _showEnd ? -widget.distance : 0,
          width: widget.nameWidth,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _ChannelFeed {
  final items = <(String, String), MediaItem>{};
  final cursors = <String>{};
  List<HomeCell> cells = const [];
  String? cursor;
  String? error;
  int generation = 0;
  bool loaded = false;
  bool loading = false;
  bool retryMore = false;
}

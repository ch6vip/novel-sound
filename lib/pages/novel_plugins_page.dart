import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../services/novel_plugins.dart';
import '../services/user_facing_error.dart';

Future<void> openNovelPlugins(BuildContext context) => Navigator.push<void>(
  context,
  MaterialPageRoute(builder: (_) => const NovelPluginsPage()),
);

class NovelPluginsPage extends StatefulWidget {
  const NovelPluginsPage({super.key, this.registry});

  final NovelPluginRegistry? registry;

  @override
  State<NovelPluginsPage> createState() => _NovelPluginsPageState();
}

class _NovelPluginsPageState extends State<NovelPluginsPage> {
  late final _registry = widget.registry ?? NovelPluginRegistry.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _run(_registry.load);
  }

  Future<void> _run(Future<void> Function() command) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await command();
    } catch (error) {
      if (mounted) {
        _message(userFacingError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _importZip() => _run(() async {
    const group = XTypeGroup(
      label: 'ZIP',
      extensions: ['zip'],
      mimeTypes: ['application/zip', 'application/x-zip-compressed'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null || !mounted) return;
    final info = await _registry.inspectZip(file.path);
    if (!mounted) return;
    final name = info['name'] as String;
    final version = info['version'] as String;
    final hosts = (info['httpsHosts'] as List).cast<String>();
    final oldPublisher = info['resetPublisher'] as String?;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(oldPublisher == null ? '导入 $name' : '重置并导入 $name'),
        content: SingleChildScrollView(
          child: Text(
            [
              '${info['sourceId']} · $version',
              '签名公钥 ${info['publisher']}',
              if (oldPublisher != null) ...[
                '旧签名公钥 $oldPublisher',
                '继续将重置该插件的私有存储。书架、进度、书签和离线缓存会保留。',
              ],
              if (hosts.isNotEmpty) '可访问的站点',
              ...hosts,
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(oldPublisher == null ? '导入' : '重置并导入'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _registry.installZip(
      file.path,
      info['fingerprint'] as String,
      resetPublisher: oldPublisher,
    );
    if (mounted) _message('已导入 $name $version');
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('书源插件')),
    body: ListenableBuilder(
      listenable: _registry,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_registry.supportsZipPackages)
            FilledButton.icon(
              onPressed: _busy ? null : _importZip,
              icon: const Icon(Icons.folder_zip_outlined),
              label: const Text('导入或更新插件 ZIP'),
            ),
          if (!_registry.supportsZipPackages)
            const ListTile(title: Text('此平台暂不可导入 ZIP 插件')),
          for (final plugin in [
            ..._registry.plugins,
            ..._registry.legacyPlugins,
          ])
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(plugin.name),
              subtitle: Text(
                '${plugin.version} · ZIP 插件${plugin.needsReimport ? ' · 待重新导入' : ''}',
              ),
              trailing: IconButton(
                tooltip: '卸载 ${plugin.name}',
                onPressed: _busy
                    ? null
                    : () => _run(() => _registry.uninstall(plugin.id)),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        ],
      ),
    ),
  );
}

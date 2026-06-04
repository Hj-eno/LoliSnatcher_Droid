import 'package:flutter/material.dart';

import 'package:get/get.dart';

import 'package:lolisnatcher/src/boorus/eagle_handler.dart';
import 'package:lolisnatcher/src/data/eagle_folder.dart';
import 'package:lolisnatcher/src/handlers/search_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';

/// Drawer section that shows the current Eagle library's folder tree.
/// Tapping a folder runs a `folder:<name>` search in the current tab.
///
/// Only rendered when the current booru is an Eagle booru (see MainDrawer).
class EagleFolderDrawer extends StatefulWidget {
  const EagleFolderDrawer({required this.handler, super.key});

  final EagleHandler handler;

  @override
  State<EagleFolderDrawer> createState() => _EagleFolderDrawerState();
}

class _EagleFolderDrawerState extends State<EagleFolderDrawer> {
  late Future<List<EagleFolder>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.handler.loadFolders();
  }

  @override
  void didUpdateWidget(covariant EagleFolderDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // current booru/tab changed -> load the new handler's folders
    if (!identical(oldWidget.handler, widget.handler)) {
      _future = widget.handler.loadFolders();
    }
  }

  void _refresh() {
    setState(() {
      _future = widget.handler.loadFolders(force: true);
    });
  }

  void _toggleSubfolders(bool value) {
    final SettingsHandler settingsHandler = SettingsHandler.instance;
    settingsHandler.eagleShowSubfolderItems.value = value;
    settingsHandler.saveSettings(restate: false);
    // re-apply immediately if the current tab is filtering by a folder
    final tab = SearchHandler.instance.currentTab;
    if (tab.tags.contains('folder:')) {
      SearchHandler.instance.searchAction(tab.tags, null);
    }
  }

  void _searchFolder(EagleFolder folder) {
    // use underscores for spaces so it stays a single search-bar chip
    // (the handler resolves underscores back to spaces). Quotes would render
    // as two broken chips.
    final String query = 'folder:${folder.name.replaceAll(' ', '_')}';
    SearchHandler.instance.searchAction(query, null);

    final ScaffoldState? scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isEndDrawerOpen ?? false) {
      scaffold!.closeEndDrawer();
    } else if (scaffold?.isDrawerOpen ?? false) {
      scaffold!.closeDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.folder_copy_outlined, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Eagle folders', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Obx(() {
                final bool on = SettingsHandler.instance.eagleShowSubfolderItems.value;
                return IconButton(
                  icon: Icon(on ? Icons.account_tree : Icons.account_tree_outlined),
                  color: on ? Theme.of(context).colorScheme.primary : null,
                  tooltip: 'Include subfolder items',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _toggleSubfolders(!on),
                );
              }),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: context.loc.retry,
                visualDensity: VisualDensity.compact,
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        FutureBuilder<List<EagleFolder>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              );
            }
            final List<EagleFolder> folders = snapshot.data ?? const [];
            if (folders.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(context.loc.nothingFound),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final folder in folders) _FolderNode(folder: folder, depth: 0, onTap: _searchFolder),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FolderNode extends StatefulWidget {
  const _FolderNode({required this.folder, required this.depth, required this.onTap});

  final EagleFolder folder;
  final int depth;
  final void Function(EagleFolder) onTap;

  @override
  State<_FolderNode> createState() => _FolderNodeState();
}

class _FolderNodeState extends State<_FolderNode> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final EagleFolder folder = widget.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => widget.onTap(folder),
          child: Padding(
            padding: EdgeInsets.only(left: 16 + widget.depth * 16, right: 4, top: 8, bottom: 8),
            child: Row(
              children: [
                Icon(folder.hasChildren ? Icons.folder : Icons.image_outlined, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(folder.name, overflow: TextOverflow.ellipsis),
                ),
                if (folder.hasChildren)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final child in folder.children)
            _FolderNode(folder: child, depth: widget.depth + 1, onTap: widget.onTap),
      ],
    );
  }
}

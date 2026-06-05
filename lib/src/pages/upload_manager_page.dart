import 'dart:io';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/upload_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/booru_handler_factory.dart';
import 'package:lolisnatcher/src/handlers/upload_handler.dart';

/// Persistent upload queue UI: shows everything staged to be pushed into a
/// library (Eagle/Hydrus), their tags/folder/target, and transfer status.
/// Edit metadata per item, then upload one or all.
class UploadManagerPage extends StatelessWidget {
  const UploadManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = UploadHandler.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Manager'),
        actions: [
          IconButton(
            tooltip: 'Add local files',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () => _pickLocalFiles(context),
          ),
          IconButton(
            tooltip: 'Add from URL',
            icon: const Icon(Icons.add_link),
            onPressed: () => _addFromUrlDialog(context),
          ),
          Obx(() {
            final busy = handler.isBusy.value;
            final hasWork = handler.queue.any((e) => e.status.isPending || e.status.isFailed);
            return IconButton(
              tooltip: 'Upload all',
              icon: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_outlined),
              onPressed: (busy || !hasWork) ? null : handler.uploadAll,
            );
          }),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'clearDone':
                  await handler.clearCompleted();
                  break;
                case 'clearAll':
                  final ok = await _confirm(context, 'Clear the entire queue?');
                  if (ok) await handler.clearAll();
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clearDone', child: Text('Clear completed')),
              PopupMenuItem(value: 'clearAll', child: Text('Clear all')),
            ],
          ),
        ],
      ),
      body: Obx(() {
        handler.queue.length; // react to queue changes
        final items = handler.queue;
        if (items.isEmpty) {
          return _emptyState(context);
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _UploadCard(item: items[i]),
        );
      }),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 64, color: Theme.of(context).disabledColor),
            const SizedBox(height: 16),
            const Text(
              'Nothing queued',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Add items from the viewer\'s share menu ("Add to upload queue"), '
              'or tap the link icon above to queue a URL.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLocalFiles(BuildContext context) async {
    try {
      final List<XFile> files = await ImagePicker().pickMultipleMedia();
      if (files.isEmpty) {
        return;
      }
      int staged = 0;
      for (final f in files) {
        final entry = await UploadHandler.instance.stageLocalFile(f.path, displayName: _stripExt(f.name));
        if (entry != null) {
          staged++;
        }
      }
      if (context.mounted && staged > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $staged file${staged == 1 ? '' : 's'} to the queue'), duration: const Duration(seconds: 2)),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not pick files')),
        );
      }
    }
  }

  static String _stripExt(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _addFromUrlDialog(BuildContext context) async {
    final urlCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final res = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Queue a URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'File URL', hintText: 'https://…'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Add')),
          ],
        );
      },
    );
    if (res == true && urlCtrl.text.trim().isNotEmpty) {
      final url = urlCtrl.text.trim();
      final name = nameCtrl.text.trim().isNotEmpty
          ? nameCtrl.text.trim()
          : (Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const <String>[])
                .let((s) => s.isNotEmpty ? s.last : 'item');
      await UploadHandler.instance.add(
        UploadItem(name: name, source: UploadSource.url, fileUrl: url),
      );
    }
  }

  static Future<bool> _confirm(BuildContext context, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('OK')),
        ],
      ),
    );
    return res ?? false;
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.item});

  final UploadItem item;

  @override
  Widget build(BuildContext context) {
    final handler = UploadHandler.instance;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      leading: _thumb(context),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              _statusChip(context),
              if (item.folderLabel != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 14),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(
                          item.folderLabel!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (item.tags.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.tags.take(6).join(', ') + (item.tags.length > 6 ? ' +${item.tags.length - 6}' : ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
          ],
          if (item.error != null) ...[
            const SizedBox(height: 4),
            Text(item.error!, style: const TextStyle(fontSize: 12, color: Colors.red), maxLines: 2),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'upload':
              await handler.uploadOne(item);
              break;
            case 'retry':
              await handler.retry(item);
              break;
            case 'edit':
              if (context.mounted) await _editDialog(context, item);
              break;
            case 'remove':
              await handler.remove(item);
              break;
          }
        },
        itemBuilder: (context) => [
          if (item.status.isPending || item.status.isFailed)
            const PopupMenuItem(value: 'upload', child: Text('Upload now')),
          if (item.status.isDone || item.status.isFailed)
            const PopupMenuItem(value: 'retry', child: Text('Re-queue')),
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
      onTap: () => _editDialog(context, item),
    );
  }

  Widget _thumb(BuildContext context) {
    final fallback = Container(
      width: 52,
      height: 52,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.image_outlined, color: Theme.of(context).hintColor),
    );

    Widget wrap(Widget child) => ClipRRect(borderRadius: BorderRadius.circular(6), child: child);

    // Local files are on disk, not over HTTP.
    if (item.source == UploadSource.localFile) {
      final p = item.localPath;
      if (p == null || !File(p).existsSync()) {
        return wrap(fallback);
      }
      return wrap(
        Image.file(
          File(p),
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    final url = item.thumbnailUrl;
    if (url == null || url.isEmpty) {
      return wrap(fallback);
    }
    return wrap(
      Image.network(
        url,
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
      ),
    );
  }

  Widget _statusChip(BuildContext context) {
    final (Color color, IconData icon, String label) = switch (item.status) {
      UploadStatus.pending => (Colors.blueGrey, Icons.schedule, 'Pending'),
      UploadStatus.uploading => (Colors.blue, Icons.sync, 'Uploading'),
      UploadStatus.done => (Colors.green, Icons.check_circle, 'Done'),
      UploadStatus.failed => (Colors.red, Icons.error, 'Failed'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _editDialog(BuildContext context, UploadItem item) {
    return showDialog(
      context: context,
      builder: (context) => _EditUploadDialog(item: item),
    );
  }
}

class _EditUploadDialog extends StatefulWidget {
  const _EditUploadDialog({required this.item});

  final UploadItem item;

  @override
  State<_EditUploadDialog> createState() => _EditUploadDialogState();
}

class _EditUploadDialogState extends State<_EditUploadDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _annotationCtrl;
  final TextEditingController _tagCtrl = TextEditingController();
  late List<String> _tags;
  String? _folderId;
  String? _folderLabel;
  Booru? _target;

  List<Booru> get _targets => UploadHandler.instance.targetBoorus;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.item.name);
    _annotationCtrl = TextEditingController(text: widget.item.annotation ?? '');
    _tags = [...widget.item.tags];
    _folderId = widget.item.folderId;
    _folderLabel = widget.item.folderLabel;
    final targets = _targets;
    _target = targets.firstWhereOrNull((b) => b.name == widget.item.targetBooruName) ??
        (targets.isNotEmpty ? targets.first : null);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _annotationCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  BooruHandler? get _targetHandler =>
      _target == null ? null : BooruHandlerFactory().getBooruHandler([_target!], null).booruHandler;

  void _addTag() {
    final t = _tagCtrl.text.trim();
    if (t.isNotEmpty && !_tags.contains(t)) {
      setState(() => _tags.add(t));
    }
    _tagCtrl.clear();
  }

  Future<void> _pickFolder() async {
    final handler = _targetHandler;
    if (handler == null || !handler.hasItemAddFolders) {
      return;
    }
    final choice = await showDialog<({String? id, String? label})>(
      context: context,
      builder: (context) => _FolderPicker(handler: handler),
    );
    if (choice != null) {
      setState(() {
        _folderId = choice.id;
        _folderLabel = choice.label;
      });
    }
  }

  void _save() {
    final item = widget.item;
    item.name = _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : item.name;
    item.annotation = _annotationCtrl.text.trim().isNotEmpty ? _annotationCtrl.text.trim() : null;
    item.tags = _tags;
    item.folderId = _folderId;
    item.folderLabel = _folderLabel;
    item.targetBooruName = _target?.name;
    UploadHandler.instance.saveItem(item);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    return AlertDialog(
      title: const Text('Edit upload'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              if (targets.length > 1)
                DropdownButtonFormField<Booru>(
                  initialValue: _target,
                  decoration: const InputDecoration(labelText: 'Target library'),
                  items: [
                    for (final b in targets)
                      DropdownMenuItem(
                        value: b,
                        child: Text(b.name?.isNotEmpty == true ? b.name! : (b.type?.alias ?? 'Library')),
                      ),
                  ],
                  onChanged: (b) => setState(() {
                    _target = b;
                    _folderId = null;
                    _folderLabel = null;
                  }),
                ),
              const SizedBox(height: 8),
              if (_targetHandler?.hasItemAddFolders == true)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(_folderLabel?.trim() ?? 'No folder (library root)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickFolder,
                ),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft, child: Text('Tags')),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in _tags)
                    Chip(
                      label: Text(t),
                      onDeleted: () => setState(() => _tags.remove(t)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tagCtrl,
                      decoration: const InputDecoration(hintText: 'Add a tag', isDense: true),
                      onSubmitted: (_) => _addTag(),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.add), onPressed: _addTag),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _annotationCtrl,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Annotation / notes'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Folder picker returning `(id, label)`; id null = library root.
class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.handler});

  final BooruHandler handler;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  List<({String id, String label})>? _folders;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final folders = await widget.handler.addTargetFolders();
    if (mounted) {
      setState(() => _folders = folders);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _folders;
    final shown = (all ?? [])
        .where((f) => _filter.isEmpty || f.label.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('Choose a folder'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (all != null && all.isNotEmpty)
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter', isDense: true),
                onChanged: (v) => setState(() => _filter = v),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: all == null
                  ? const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.inbox_outlined),
                          title: const Text('No folder (library root)'),
                          onTap: () => Navigator.of(context).pop((id: null, label: null)),
                        ),
                        const Divider(height: 1),
                        for (final f in shown)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(f.label),
                            onTap: () => Navigator.of(context).pop((id: f.id, label: f.label)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ],
    );
  }
}

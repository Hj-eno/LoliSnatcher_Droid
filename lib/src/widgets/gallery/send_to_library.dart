import 'package:flutter/material.dart';

import 'package:lolisnatcher/src/boorus/booru_type.dart';
import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/booru_handler_factory.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/widgets/common/flash_elements.dart';

/// Modular "send to library" pipeline.
///
/// Pushes a [BooruItem] into another booru that supports receiving items
/// (currently Eagle and Hydrus — see [BooruType.itemAddTargets]). The flow is
/// fully generic: it discovers eligible targets, lets the user pick one (and a
/// destination folder if the target supports it), then calls the handler's
/// `addItem`. Adding a new upload-capable booru only requires implementing
/// `BooruHandler.addItem` + listing its type in `BooruType.itemAddTargets`;
/// no changes here.
///
/// [excludeBooru] omits the booru the item is currently being viewed from
/// (no point sending an item back to where it came from).
Future<void> sendItemToLibrary(
  BuildContext context,
  BooruItem item, {
  Booru? excludeBooru,
  bool usePostUrl = false,
}) async {
  final settingsHandler = SettingsHandler.instance;

  final List<Booru> targets = settingsHandler.booruList
      .where((b) => b.type?.supportsItemAdd == true && b != excludeBooru)
      .toList();

  if (targets.isEmpty) {
    FlashElements.showSnackbar(
      context: context,
      title: const Text('No library to send to', style: TextStyle(fontSize: 20)),
      content: const Text('Add an Eagle or Hydrus booru in settings first.'),
      leadingIcon: Icons.warning_amber,
      leadingIconColor: Colors.orange,
      sideColor: Colors.orange,
    );
    return;
  }

  final Booru? target = targets.length == 1 ? targets.first : await _pickTarget(context, targets);
  if (target == null) {
    return;
  }

  final BooruHandler handler = BooruHandlerFactory().getBooruHandler([target], null).booruHandler;
  if (!handler.hasItemAddSupport) {
    return;
  }

  String? folderId;
  if (handler.hasItemAddFolders) {
    if (!context.mounted) {
      return;
    }
    final _FolderChoice? choice = await _pickFolder(context, handler);
    if (choice == null) {
      // user cancelled the folder step entirely
      return;
    }
    folderId = choice.id; // null => library root (no folder)
  }

  final bool ok = await handler.addItem(item, usePostUrl: usePostUrl, folderId: folderId);

  if (!context.mounted) {
    return;
  }
  final String targetName = target.name?.isNotEmpty == true ? target.name! : (target.type?.alias ?? 'library');
  if (ok) {
    FlashElements.showSnackbar(
      context: context,
      title: Text('Sent to $targetName', style: const TextStyle(fontSize: 20)),
      leadingIcon: Icons.check_circle_outline,
      leadingIconColor: Colors.green,
      sideColor: Colors.green,
      duration: const Duration(seconds: 2),
    );
  } else {
    FlashElements.showSnackbar(
      context: context,
      title: Text('Failed to send to $targetName', style: const TextStyle(fontSize: 20)),
      content: const Text('The library rejected the item or is unreachable.'),
      leadingIcon: Icons.error_outline,
      leadingIconColor: Colors.red,
      sideColor: Colors.red,
    );
  }
}

/// Pick which configured library to send to (only shown when >1 exists).
Future<Booru?> _pickTarget(BuildContext context, List<Booru> targets) {
  return showDialog<Booru>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Send to which library?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final b in targets)
              ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined),
                title: Text(b.name?.isNotEmpty == true ? b.name! : (b.type?.alias ?? 'Library')),
                subtitle: Text(b.type?.alias ?? ''),
                onTap: () => Navigator.of(context).pop(b),
              ),
            ListTile(
              leading: const Icon(Icons.cancel_outlined),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    },
  );
}

/// A chosen destination folder. [id] of null means "library root / no folder".
class _FolderChoice {
  const _FolderChoice(this.id);
  final String? id;
}

/// Pick a destination folder for targets that support it (e.g. Eagle).
/// Returns null if the user cancels; a [_FolderChoice] (possibly with a null
/// id, meaning "no folder") otherwise.
Future<_FolderChoice?> _pickFolder(BuildContext context, BooruHandler handler) {
  return showDialog<_FolderChoice>(
    context: context,
    builder: (context) => _FolderPickerDialog(handler: handler),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({required this.handler});

  final BooruHandler handler;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  List<({String id, String label})>? _folders;
  String _filter = '';
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final folders = await widget.handler.addTargetFolders();
      if (mounted) {
        setState(() => _folders = folders);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _folders;
    final List<({String id, String label})> shown = (all ?? [])
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
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Filter folders',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: _error
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Could not load folders.'),
                    )
                  : all == null
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.inbox_outlined),
                          title: const Text('No folder (library root)'),
                          onTap: () => Navigator.of(context).pop(const _FolderChoice(null)),
                        ),
                        const Divider(height: 1),
                        for (final f in shown)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(f.label),
                            onTap: () => Navigator.of(context).pop(_FolderChoice(f.id)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

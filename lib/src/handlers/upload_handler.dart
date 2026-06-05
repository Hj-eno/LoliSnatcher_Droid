import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'package:lolisnatcher/src/data/booru.dart';
import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/tag.dart';
import 'package:lolisnatcher/src/data/upload_item.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/booru_handler_factory.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/logger.dart';

/// Persistent, modular upload queue + history.
///
/// Holds a list of [UploadItem]s staged to be pushed into a library booru
/// (Eagle/Hydrus). The queue survives restarts (saved as JSON next to the
/// app's settings). Transfer is delegated to each handler's `addItem`, so the
/// queue is target-agnostic.
///
/// Self-registering singleton: `UploadHandler.instance` constructs + loads on
/// first use, no wiring in main().
class UploadHandler extends GetxController {
  static UploadHandler get instance =>
      Get.isRegistered<UploadHandler>() ? Get.find<UploadHandler>() : Get.put(UploadHandler());

  final RxList<UploadItem> queue = <UploadItem>[].obs;

  /// Set true while [uploadAll] is running, so the UI can disable controls.
  final RxBool isBusy = false.obs;

  bool _loaded = false;

  int get pendingCount => queue.where((e) => e.status.isPending).length;
  int get activeCount => queue.where((e) => e.status.isPending || e.status.isUploading).length;

  @override
  void onInit() {
    super.onInit();
    unawaited(load());
  }

  String get _filePath {
    final String base = SettingsHandler.instance.path;
    return '${base}upload_queue.json';
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    try {
      if (SettingsHandler.instance.path.isEmpty) {
        await SettingsHandler.instance.setConfigDir();
      }
      final File f = File(_filePath);
      if (await f.exists()) {
        final String raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final dynamic decoded = jsonDecode(raw);
          if (decoded is List) {
            queue.value = decoded
                .whereType<Map>()
                .map((e) => UploadItem.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
        }
      }
      // a job left mid-flight by a crash/exit should be retryable, not stuck
      for (final item in queue) {
        if (item.status.isUploading) {
          item.status = UploadStatus.pending;
        }
      }
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'UploadHandler', 'load', LogTypes.exception, s: s);
    } finally {
      _loaded = true;
    }
  }

  Future<void> persist() async {
    try {
      if (SettingsHandler.instance.path.isEmpty) {
        await SettingsHandler.instance.setConfigDir();
      }
      final File f = File(_filePath);
      await f.writeAsString(jsonEncode(queue.map((e) => e.toJson()).toList()));
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'UploadHandler', 'persist', LogTypes.exception, s: s);
    }
  }

  // ---- queue mutations -----------------------------------------------------

  Future<void> add(UploadItem item) async {
    queue.add(item);
    queue.refresh();
    await persist();
  }

  Future<void> addAll(Iterable<UploadItem> items) async {
    queue.addAll(items);
    queue.refresh();
    await persist();
  }

  /// Queue a booru item (viewed or snatched). Returns the created entry.
  Future<UploadItem> addFromBooruItem(BooruItem item, {bool snatched = false}) async {
    final entry = UploadItem.fromBooruItem(item, snatched: snatched);
    await add(entry);
    return entry;
  }

  /// Directory where picked local files are copied so the queue can reference
  /// them across restarts (the OS may clear the picker's own cache).
  Future<Directory> _stagingDir() async {
    if (SettingsHandler.instance.path.isEmpty) {
      await SettingsHandler.instance.setConfigDir();
    }
    final dir = Directory('${SettingsHandler.instance.path}upload_staging');
    await dir.create(recursive: true);
    return dir;
  }

  /// Copy a picked local file into the staging dir and queue it. Returns the
  /// created entry (or null if the source couldn't be read).
  Future<UploadItem?> stageLocalFile(String sourcePath, {String? displayName}) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) {
        return null;
      }
      final dir = await _stagingDir();
      final String fname = sourcePath.split(RegExp(r'[\\/]')).last;
      final int dot = fname.lastIndexOf('.');
      final String ext = dot > 0 ? fname.substring(dot) : '';
      final String baseName = displayName ?? (dot > 0 ? fname.substring(0, dot) : fname);
      final String id = const Uuid().v4();
      final File dest = File('${dir.path}${Platform.pathSeparator}$id$ext');
      await src.copy(dest.path);

      final entry = UploadItem(
        name: baseName.isNotEmpty ? baseName : 'file',
        source: UploadSource.localFile,
        localPath: dest.path,
        thumbnailUrl: dest.path,
      );
      await add(entry);
      return entry;
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'UploadHandler', 'stageLocalFile', LogTypes.exception, s: s);
      return null;
    }
  }

  /// Delete a staged local file once it's no longer needed.
  Future<void> _deleteStaged(UploadItem item) async {
    final String? p = item.localPath;
    if (item.source != UploadSource.localFile || p == null) {
      return;
    }
    try {
      final f = File(p);
      if (p.contains('upload_staging') && await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> remove(UploadItem item) async {
    queue.remove(item);
    queue.refresh();
    await _deleteStaged(item);
    await persist();
  }

  Future<void> clearCompleted() async {
    for (final e in queue.where((e) => e.status.isDone)) {
      await _deleteStaged(e);
    }
    queue.removeWhere((e) => e.status.isDone);
    queue.refresh();
    await persist();
  }

  Future<void> clearAll() async {
    for (final e in queue) {
      await _deleteStaged(e);
    }
    queue.clear();
    await persist();
  }

  Future<void> saveItem(UploadItem item) async {
    queue.refresh();
    await persist();
  }

  // ---- target resolution ---------------------------------------------------

  /// Configured boorus that can receive items.
  List<Booru> get targetBoorus =>
      SettingsHandler.instance.booruList.where((b) => b.type?.supportsItemAdd == true).toList();

  Booru? _resolveTarget(UploadItem item) {
    final List<Booru> targets = targetBoorus;
    if (targets.isEmpty) {
      return null;
    }
    if (item.targetBooruName != null) {
      for (final b in targets) {
        if (b.name == item.targetBooruName) {
          return b;
        }
      }
    }
    return targets.first;
  }

  // ---- transfer ------------------------------------------------------------

  /// Upload a single queued item. Returns true on success. Updates the item's
  /// status + persists either way.
  Future<bool> uploadOne(UploadItem item) async {
    if (item.status.isUploading) {
      return false;
    }

    final bool isLocal = item.source == UploadSource.localFile;
    if (isLocal && (item.localPath == null || !File(item.localPath!).existsSync())) {
      item.status = UploadStatus.failed;
      item.error = 'The local file is missing (it may have been cleared).';
      await saveItem(item);
      return false;
    }

    final Booru? target = _resolveTarget(item);
    if (target == null) {
      item.status = UploadStatus.failed;
      item.error = 'No library configured to receive uploads.';
      await saveItem(item);
      return false;
    }
    item.targetBooruName = target.name;

    item.status = UploadStatus.uploading;
    item.error = null;
    await saveItem(item);

    try {
      final BooruHandler handler = BooruHandlerFactory().getBooruHandler([target], null).booruHandler;

      final bool ok;
      if (isLocal) {
        if (!handler.hasLocalUploadSupport) {
          item.status = UploadStatus.failed;
          item.error = 'Target has no local-file upload. Point its image server at eagle-serve.';
          await saveItem(item);
          return false;
        }
        ok = await handler.addLocalFile(
          item.localPath!,
          name: item.name,
          tags: item.tags,
          folderId: item.folderId,
          website: item.postUrl,
          annotation: item.annotation,
        );
      } else {
        if (!handler.hasItemAddSupport) {
          item.status = UploadStatus.failed;
          item.error = 'Target booru does not support uploads.';
          await saveItem(item);
          return false;
        }
        ok = await handler.addItem(_toBooruItem(item), folderId: item.folderId);
      }

      item.status = ok ? UploadStatus.done : UploadStatus.failed;
      item.error = ok ? null : 'The library rejected the item or is unreachable.';
      item.completedAt = ok ? DateTime.now() : null;
      await saveItem(item);
      if (ok && isLocal) {
        await _deleteStaged(item); // Eagle copied it into the library; staging copy is disposable
      }
      return ok;
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'UploadHandler', 'uploadOne', LogTypes.exception, s: s);
      item.status = UploadStatus.failed;
      item.error = e.toString();
      await saveItem(item);
      return false;
    }
  }

  /// Upload every pending (and previously failed) item, sequentially.
  Future<void> uploadAll() async {
    if (isBusy.value) {
      return;
    }
    isBusy.value = true;
    try {
      // snapshot so edits during the run don't disturb iteration
      final List<UploadItem> todo =
          queue.where((e) => e.status.isPending || e.status.isFailed).toList();
      for (final item in todo) {
        await uploadOne(item);
      }
    } finally {
      isBusy.value = false;
    }
  }

  /// Re-queue a finished/failed item for another attempt.
  Future<void> retry(UploadItem item) async {
    item.status = UploadStatus.pending;
    item.error = null;
    item.completedAt = null;
    await saveItem(item);
  }

  /// Adapt the queue entry into the minimal BooruItem the handlers consume.
  BooruItem _toBooruItem(UploadItem item) {
    return BooruItem(
      fileURL: item.fileUrl ?? '',
      sampleURL: item.thumbnailUrl ?? '',
      thumbnailURL: item.thumbnailUrl ?? '',
      tagsList: item.tags.map(Tag.new).toList(),
      postURL: item.postUrl ?? item.fileUrl ?? '',
      serverId: item.name,
      sources: item.postUrl != null ? [item.postUrl!] : null,
      description: item.annotation,
    );
  }
}

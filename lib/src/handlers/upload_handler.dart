import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';

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

  Future<void> remove(UploadItem item) async {
    queue.remove(item);
    queue.refresh();
    await persist();
  }

  Future<void> clearCompleted() async {
    queue.removeWhere((e) => e.status.isDone);
    queue.refresh();
    await persist();
  }

  Future<void> clearAll() async {
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
    if (item.source == UploadSource.localFile && (item.fileUrl == null || item.fileUrl!.isEmpty)) {
      item.status = UploadStatus.failed;
      item.error = 'Local file upload needs the eagle-serve upload endpoint (not yet available).';
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
      if (!handler.hasItemAddSupport) {
        item.status = UploadStatus.failed;
        item.error = 'Target booru does not support uploads.';
        await saveItem(item);
        return false;
      }

      final BooruItem booruItem = _toBooruItem(item);
      final bool ok = await handler.addItem(booruItem, folderId: item.folderId);

      item.status = ok ? UploadStatus.done : UploadStatus.failed;
      item.error = ok ? null : 'The library rejected the item or is unreachable.';
      item.completedAt = ok ? DateTime.now() : null;
      await saveItem(item);
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

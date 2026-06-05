import 'package:uuid/uuid.dart';

import 'package:lolisnatcher/src/data/booru_item.dart';

/// Where the bytes for an upload come from.
enum UploadSource {
  /// A remote URL the target library fetches itself (booru file/post URL).
  /// Works with Eagle `addFromURL` and Hydrus `add_url`.
  url,

  /// An item already snatched/downloaded by LoliSnatcher. Still carries its
  /// original booru URL, so it's uploaded the same way as [url].
  snatched,

  /// A file picked from the local device. Cannot be pushed to a *remote* Eagle
  /// via the metadata API (Eagle can't read the phone's disk); needs the
  /// eagle-serve upload endpoint. Tracked here for a future transfer path.
  localFile;

  String toJson() => name;

  static UploadSource fromJson(String? v) =>
      UploadSource.values.firstWhere((e) => e.name == v, orElse: () => UploadSource.url);
}

/// Lifecycle of a queued upload.
enum UploadStatus {
  pending,
  uploading,
  done,
  failed;

  String toJson() => name;

  static UploadStatus fromJson(String? v) =>
      UploadStatus.values.firstWhere((e) => e.name == v, orElse: () => UploadStatus.pending);

  bool get isPending => this == UploadStatus.pending;
  bool get isUploading => this == UploadStatus.uploading;
  bool get isDone => this == UploadStatus.done;
  bool get isFailed => this == UploadStatus.failed;
}

/// One entry in the persistent upload queue: a thing to push into a library
/// (Eagle/Hydrus), the metadata it should carry, and its transfer state.
class UploadItem {
  UploadItem({
    required this.name,
    required this.source,
    String? id,
    this.fileUrl,
    this.postUrl,
    this.thumbnailUrl,
    this.localPath,
    List<String>? tags,
    this.annotation,
    this.targetBooruName,
    this.folderId,
    this.folderLabel,
    this.status = UploadStatus.pending,
    this.error,
    DateTime? createdAt,
    this.completedAt,
  })  : id = id ?? const Uuid().v4(),
        tags = tags ?? <String>[],
        createdAt = createdAt ?? DateTime.now();

  /// Build a queue entry from a viewed/snatched booru item.
  factory UploadItem.fromBooruItem(
    BooruItem item, {
    bool snatched = false,
  }) {
    final String? sid = item.serverId;
    final List<String> segs =
        Uri.tryParse(item.fileURL)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    final String fallbackName = (sid != null && sid.isNotEmpty)
        ? sid
        : (segs.isNotEmpty ? segs.last : 'item');
    return UploadItem(
      name: fallbackName,
      source: snatched ? UploadSource.snatched : UploadSource.url,
      fileUrl: item.fileURL,
      postUrl: item.postURL.isNotEmpty ? item.postURL : null,
      thumbnailUrl: item.thumbnailURL.isNotEmpty ? item.thumbnailURL : item.sampleURL,
      tags: item.tagsList.map((t) => t.fullString).where((t) => !t.startsWith('folder:')).toList(),
      annotation: item.description,
    );
  }

  factory UploadItem.fromJson(Map<String, dynamic> json) {
    return UploadItem(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'item',
      source: UploadSource.fromJson(json['source'] as String?),
      fileUrl: json['fileUrl'] as String?,
      postUrl: json['postUrl'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      localPath: json['localPath'] as String?,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? <String>[],
      annotation: json['annotation'] as String?,
      targetBooruName: json['targetBooruName'] as String?,
      folderId: json['folderId'] as String?,
      folderLabel: json['folderLabel'] as String?,
      status: UploadStatus.fromJson(json['status'] as String?),
      error: json['error'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      completedAt: json['completedAt'] != null ? DateTime.tryParse(json['completedAt'] as String) : null,
    );
  }

  final String id;
  String name;
  UploadSource source;

  /// Direct file URL (the thing the library downloads).
  String? fileUrl;

  /// Source/post page URL, stored as the item's `website` in Eagle.
  String? postUrl;

  /// Thumbnail for the queue preview (not uploaded).
  String? thumbnailUrl;

  /// Local device path (for [UploadSource.localFile]).
  String? localPath;

  List<String> tags;
  String? annotation;

  /// Name of the destination booru. Null until the user/handler resolves one.
  String? targetBooruName;

  /// Destination folder/collection within the target (Eagle), if any.
  String? folderId;
  String? folderLabel;

  UploadStatus status;
  String? error;

  final DateTime createdAt;
  DateTime? completedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'source': source.toJson(),
        'fileUrl': fileUrl,
        'postUrl': postUrl,
        'thumbnailUrl': thumbnailUrl,
        'localPath': localPath,
        'tags': tags,
        'annotation': annotation,
        'targetBooruName': targetBooruName,
        'folderId': folderId,
        'folderLabel': folderLabel,
        'status': status.toJson(),
        'error': error,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
      };
}

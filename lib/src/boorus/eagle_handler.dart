import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lolisnatcher/src/data/booru_item.dart';
import 'package:lolisnatcher/src/data/eagle_folder.dart';
import 'package:lolisnatcher/src/data/tag.dart';
import 'package:lolisnatcher/src/handlers/booru_handler.dart';
import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/utils/dio_network.dart';
import 'package:lolisnatcher/src/utils/logger.dart';

/// Handler for the Eagle (eagle.cool) desktop app local HTTP API.
///
/// Eagle exposes a JSON API on `http://localhost:41595` (point it at the LAN IP
/// for remote access). Auth is a token passed as the `token` query parameter.
///
/// IMPORTANT: Eagle's API only ever returns *local filesystem paths* for files
/// and thumbnails — it never streams image bytes over HTTP. To view images on a
/// remote device the user must serve the library's `images/` directory over
/// HTTP (any static file server, or a bridge like eagle-web) and put that base
/// URL into the booru config's `userID` field (relabeled "Image server URL" in
/// the editor).
///
/// File layout inside a library: `<library>/images/<id>.info/<name>.<ext>`.
class EagleHandler extends BooruHandler {
  EagleHandler(super.booru, super.limit);

  @override
  bool get hasSizeData => true;

  String get token => booru.apiKey ?? '';

  /// Base URL that serves Eagle image bytes. Falls back to the API base so URLs
  /// are never null (the API won't return bytes, but it keeps the app from
  /// crashing if the user hasn't configured it yet).
  ///
  /// Two supported conventions, picked automatically from the URL:
  ///  - ends with `/img`  -> eagle-web bridge: `<base>/<id>` (thumb),
  ///                          `<base>/<id>?fq=true` (full res)
  ///  - anything else     -> plain static server over `<library>/images/`.
  ///                          Eagle stores both files in each `<id>.info/` folder:
  ///                          `<name>_thumbnail.png` (thumb) + `<name>.<ext>` (full)
  String get imageServer {
    final String raw = (booru.userID?.isNotEmpty == true ? booru.userID : booru.baseURL) ?? '';
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  /// eagle-web style bridge when the image server URL points at the `/img` route.
  bool get _isBridgeMode {
    final String s = imageServer.toLowerCase();
    return s.endsWith('/img') || s.endsWith('/img/');
  }

  /// Build (thumbnail, full-res) URLs for an item depending on the server mode.
  ({String thumb, String full}) _buildImageUrls(String id, String name, String ext) {
    final String base = imageServer;
    if (_isBridgeMode) {
      return (thumb: _withToken('$base/$id'), full: _withToken('$base/$id?fq=true'));
    }
    // plain static server over <library>/images/. Eagle keeps both files in the
    // item's <id>.info/ folder: the original and a <name>_thumbnail.png.
    final String dir = '$base/$id.info';
    final String encName = Uri.encodeComponent(name);
    final String full = '$dir/$encName${ext.isNotEmpty ? '.$ext' : ''}';
    final String thumb = '$dir/${encName}_thumbnail.png';
    return (thumb: _withToken(thumb), full: _withToken(full));
  }

  /// Append the Eagle token to a url. Used for API calls and for image-server
  /// URLs too — harmless for a plain static server, and lets eagle-serve
  /// (`-auth-token` set to this same token) gate image access.
  String _withToken(String url) {
    if (token.isEmpty) {
      return url;
    }
    final String sep = url.contains('?') ? '&' : '?';
    return '$url${sep}token=$token';
  }

  /// Verify connectivity + token against /api/application/info.
  /// Used by the booru editor's "test" flow.
  Future<bool> verifyApiAccess() async {
    try {
      final response = await DioNetwork.get(
        _withToken('${booru.baseURL}/api/application/info'),
        headers: getHeaders(),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = response.data is String ? jsonDecode(response.data) : response.data;
        return data['status'] == 'success';
      }
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'EagleHandler', 'verifyApiAccess', LogTypes.exception, s: s);
    }
    return false;
  }

  // ---- folders -------------------------------------------------------------
  // Eagle's item list filters folders by *id*, but users search by name
  // (`folder:References`), so we fetch the folder tree once and resolve names.

  final Map<String, String> _folderNameToId = {}; // lowercased name -> id
  final Map<String, String> _folderPathToId = {}; // lowercased a/b/c  -> id
  final Map<String, EagleFolder> _folderById = {}; // id -> node (for descendants)
  final Map<String, String> _folderIdToPath = {}; // id -> "A/B/C" (display path)
  final Set<String> _folderIds = {};
  List<EagleFolder> _folderTree = const [];
  bool _foldersLoaded = false;

  /// The cached folder tree (loaded on first search). Used by the drawer widget.
  List<EagleFolder> get folderTree => _folderTree;

  @override
  Future<bool> searchSetup() async {
    if (!_foldersLoaded) {
      await loadFolders();
    }
    return super.searchSetup();
  }

  /// Fetch + index the library folder tree from /api/folder/list.
  Future<List<EagleFolder>> loadFolders({bool force = false}) async {
    if (_foldersLoaded && !force) {
      return _folderTree;
    }
    try {
      final response = await DioNetwork.get(
        _withToken('${booru.baseURL}/api/folder/list'),
        headers: getHeaders(),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = response.data is String ? jsonDecode(response.data) : response.data;
        final dynamic list = data['data'];
        _folderTree = list is List
            ? list.whereType<Map<String, dynamic>>().map(EagleFolder.fromJson).toList()
            : const [];
        _folderNameToId.clear();
        _folderPathToId.clear();
        _folderById.clear();
        _folderIdToPath.clear();
        _folderIds.clear();
        _indexFolders(_folderTree, const [], const []);
        _foldersLoaded = true;
      }
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'EagleHandler', 'loadFolders', LogTypes.exception, s: s);
    }
    return _folderTree;
  }

  void _indexFolders(List<EagleFolder> folders, List<String> parents, List<String> realParents) {
    for (final f in folders) {
      _folderIds.add(f.id);
      _folderById[f.id] = f;
      final String lower = f.name.toLowerCase();
      _folderNameToId.putIfAbsent(lower, () => f.id);
      final String path = [...parents, lower].join('/');
      _folderPathToId.putIfAbsent(path, () => f.id);
      _folderIdToPath[f.id] = [...realParents, f.name].join('/');
      _indexFolders(f.children, [...parents, lower], [...realParents, f.name]);
    }
  }

  /// A folder id plus all of its descendant folder ids (for recursive filtering).
  List<String> _withDescendants(String id) {
    final EagleFolder? root = _folderById[id];
    if (root == null) {
      return [id];
    }
    final List<String> ids = [];
    void collect(EagleFolder f) {
      ids.add(f.id);
      for (final child in f.children) {
        collect(child);
      }
    }

    collect(root);
    return ids;
  }

  /// Resolve a `folder:` value (id, name, or a/b/c path) to a folder id.
  /// Underscores are accepted in place of spaces (`Wood_04` -> "Wood 04") so a
  /// tapped/typed folder name stays a single search-bar chip.
  String _resolveFolder(String value) {
    final String v = value.trim();
    if (_folderIds.contains(v)) {
      return v;
    }
    final String lower = v.toLowerCase();
    final String? direct = _folderPathToId[lower] ?? _folderNameToId[lower];
    if (direct != null) {
      return direct;
    }
    final String spaced = lower.replaceAll('_', ' ');
    return _folderPathToId[spaced] ?? _folderNameToId[spaced] ?? v;
  }

  @override
  String validateTags(String tags) {
    // Keep the raw query so makeURL can parse meta tokens itself.
    // (base implementation Uri-encodes the whole string, which would break it)
    return tags.trim();
  }

  /// Extensions to keep for the current search, parsed from `type:` tokens.
  /// Applied client-side because Eagle's `ext` API param is single-value only.
  Set<String>? _typeFilterExts;

  @override
  String makeURL(String tags) {
    // Eagle's `offset` is the *page index* (0-based), NOT an item count:
    // offset=1 returns the second page of `limit` items. (Verified live.)
    final int offset = pageNum < 0 ? 0 : pageNum;
    final List<String> params = ['limit=$limit', 'offset=$offset'];

    final _EagleQuery q = _parseQuery(tags);
    _typeFilterExts = q.typeExts;
    if (q.keyword.isNotEmpty) {
      params.add('keyword=${Uri.encodeQueryComponent(q.keyword)}');
    }
    if (q.tags.isNotEmpty) {
      params.add('tags=${Uri.encodeQueryComponent(q.tags.join(','))}');
    }
    if (q.folders.isNotEmpty) {
      params.add('folders=${Uri.encodeQueryComponent(q.folders.join(','))}');
    }
    if (q.ext != null) {
      params.add('ext=${Uri.encodeQueryComponent(q.ext!)}');
    }
    if (q.orderBy != null) {
      params.add('orderBy=${q.orderBy}');
    }
    if (token.isNotEmpty) {
      params.add('token=$token');
    }

    return '${booru.baseURL}/api/item/list?${params.join('&')}';
  }

  _EagleQuery _parseQuery(String tags) {
    final List<String> keywordParts = [];
    final List<String> tagList = [];
    final List<String> folders = [];
    final Set<String> typeExts = {};
    String? ext;
    String? orderBy;

    for (final part in _tokenize(tags)) {
      if (part.startsWith('folder:')) {
        final String folderId = _resolveFolder(part.substring(7));
        if (SettingsHandler.instance.eagleShowSubfolderItems.value) {
          folders.addAll(_withDescendants(folderId));
        } else {
          folders.add(folderId);
        }
      } else if (part.startsWith('ext:')) {
        ext = part.substring(4);
      } else if (part.startsWith('type:')) {
        typeExts.addAll(_resolveType(part.substring(5)));
      } else if (part.startsWith('keyword:')) {
        keywordParts.add(part.substring(8));
      } else if (part.startsWith('order:') || part.startsWith('sort:')) {
        orderBy = _mapOrderBy(part.substring(part.indexOf(':') + 1));
      } else {
        // Eagle tags are literal strings (may contain underscores) — send as-is.
        tagList.add(part);
      }
    }

    return _EagleQuery(
      keyword: keywordParts.join(' '),
      tags: tagList,
      folders: folders,
      ext: ext,
      orderBy: orderBy,
      typeExts: typeExts.isEmpty ? null : typeExts,
    );
  }

  /// Split a query on whitespace, but keep `"quoted phrases"` (and the value of
  /// `key:"quoted value"`) intact so tags/folders with spaces work. Underscores
  /// are preserved — Eagle tags like `some_tag` are matched literally.
  List<String> _tokenize(String input) {
    final List<String> tokens = [];
    final StringBuffer sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < input.length; i++) {
      final String c = input[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ' ' && !inQuotes) {
        if (sb.isNotEmpty) {
          tokens.add(sb.toString());
          sb.clear();
        }
      } else {
        sb.write(c);
      }
    }
    if (sb.isNotEmpty) {
      tokens.add(sb.toString());
    }
    return tokens;
  }

  /// Map a user `order:` value to an Eagle `orderBy` token. Prefix `-` (e.g.
  /// `order:-size`) or a `desc`/`asc` suffix sets the direction. The tokens
  /// below were confirmed against the live Eagle API (BTIME/MTIME/DURATION/
  /// EXT/RANDOM are honored; RATING is a best-effort no-op until items are rated).
  String? _mapOrderBy(String value) {
    String v = value.trim();
    bool? desc; // null = no explicit direction
    if (v.startsWith('-')) {
      desc = true;
      v = v.substring(1);
    } else if (v.toLowerCase().endsWith('_desc') || v.toLowerCase().endsWith(':desc')) {
      desc = true;
      v = v.substring(0, v.length - 5);
    } else if (v.toLowerCase().endsWith('_asc') || v.toLowerCase().endsWith(':asc')) {
      desc = false;
      v = v.substring(0, v.length - 4);
    }
    final String? token = switch (v.toLowerCase()) {
      'name' || 'title' => 'NAME',
      'size' || 'filesize' => 'FILESIZE',
      'resolution' || 'res' || 'dimensions' => 'RESOLUTION',
      'date' || 'added' || 'dateadded' || 'import' || 'imported' => 'BTIME',
      'modified' || 'datemodified' || 'mtime' => 'MTIME',
      'created' || 'datecreated' || 'createdate' => 'CREATEDATE',
      'ext' || 'extension' => 'EXT',
      'rating' || 'star' || 'score' => 'RATING',
      'duration' || 'length' => 'DURATION',
      'random' || 'shuffle' || 'rand' => 'RANDOM',
      _ => null,
    };
    if (token == null) {
      return null;
    }
    // rating is most useful highest-first, so default it to descending
    final bool descending = desc ?? (token == 'RATING');
    return '${descending ? '-' : ''}$token';
  }

  /// Media-type categories -> file extensions, for client-side `type:` filtering
  /// (Eagle's `ext` API param only accepts a single extension).
  static const Map<String, Set<String>> _typeExtensions = {
    'image': {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'tiff', 'tif', 'avif', 'heic', 'heif', 'jfif', 'ico', 'svg'},
    'gif': {'gif', 'apng'},
    'animation': {'gif', 'apng', 'webp'},
    'video': {'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v', 'flv', 'wmv', 'mpg', 'mpeg', 'ts', 'm2ts'},
    'audio': {'mp3', 'wav', 'flac', 'ogg', 'm4a', 'aac', 'opus', 'wma'},
  };

  /// Resolve a `type:` value to a set of extensions (a known category, or a
  /// literal extension fallback). Aliases keep it forgiving.
  Set<String> _resolveType(String value) {
    final String v = value.trim().toLowerCase();
    final String key = switch (v) {
      'img' || 'pic' || 'picture' || 'photo' || 'images' => 'image',
      'vid' || 'movie' || 'videos' => 'video',
      'sound' || 'music' => 'audio',
      'anim' || 'animated' => 'animation',
      _ => v,
    };
    return _typeExtensions[key] ?? {v};
  }

  /// Raw item count from the last server page (before client-side type filter),
  /// used to tell a fully-filtered page apart from the real end of results.
  int _lastRawPageCount = 0;

  @override
  FutureOr<List> parseListFromResponse(dynamic response) {
    final Map<String, dynamic> data = response.data is String ? jsonDecode(response.data) : response.data;
    final dynamic list = data['data'];
    final List result = list is List ? list : const [];
    _lastRawPageCount = result.length;
    return result;
  }

  @override
  Future search(String tags, int? pageNumCustom, {bool withCaptchaCheck = true}) async {
    await super.search(tags, pageNumCustom, withCaptchaCheck: withCaptchaCheck);

    // `type:` filtering is client-side (Eagle can't do multi-extension server
    // filtering), so a page may be fully dropped — which would make the base
    // class lock pagination early. While the server is still returning full
    // pages, keep pulling more until we add some items or hit the real end.
    if (_typeFilterExts != null) {
      int guard = 0;
      while (locked && errorString.isEmpty && _lastRawPageCount >= limit && guard < 10) {
        final int before = fetched.length;
        locked = false;
        pageNum++;
        await super.search(tags, null, withCaptchaCheck: withCaptchaCheck);
        guard++;
        if (fetched.length > before) {
          break;
        }
      }
    }
    return fetched;
  }

  @override
  FutureOr<BooruItem?> parseItemFromResponse(dynamic responseItem, int index) {
    final Map<String, dynamic> item = responseItem is Map<String, dynamic>
        ? responseItem
        : Map<String, dynamic>.from(responseItem);

    if (item['isDeleted'] == true) {
      return null;
    }

    final String id = item['id']?.toString() ?? '';
    if (id.isEmpty) {
      return null;
    }

    final String name = item['name']?.toString() ?? id;
    final String ext = item['ext']?.toString() ?? '';

    // client-side type filter (Eagle's ext param can't do multi-extension)
    if (_typeFilterExts != null && !_typeFilterExts!.contains(ext.toLowerCase())) {
      return null;
    }

    final List rawTags = item['tags'] is List ? item['tags'] as List : const [];
    final List<Tag> tags = rawTags.map((t) => Tag(t.toString())).toList();

    // surface the folder(s) this item lives in as tappable `folder:` tags
    // (underscores keep them single search-bar chips; resolver maps them back)
    final List rawFolders = item['folders'] is List ? item['folders'] as List : const [];
    for (final fid in rawFolders) {
      final String? path = _folderIdToPath[fid.toString()];
      if (path != null && path.isNotEmpty) {
        tags.add(Tag('folder:${path.replaceAll(' ', '_')}'));
      }
    }

    final ({String thumb, String full}) urls = _buildImageUrls(id, name, ext);

    final double? width = (item['width'] as num?)?.toDouble();
    final double? height = (item['height'] as num?)?.toDouble();
    final String? source = item['url']?.toString().isNotEmpty == true ? item['url'].toString() : null;
    final String? annotation = item['annotation']?.toString().isNotEmpty == true ? item['annotation'].toString() : null;

    return BooruItem(
      fileURL: urls.full,
      sampleURL: urls.thumb,
      thumbnailURL: urls.thumb,
      tagsList: tags,
      postURL: source ?? urls.full,
      fileExt: ext.isNotEmpty ? ext : null,
      fileWidth: width,
      fileHeight: height,
      fileSize: (item['size'] as num?)?.toInt(),
      serverId: id,
      md5String: id,
      sources: source != null ? [source] : null,
      description: annotation,
      rating: (item['star'] is num) ? (item['star'] as num).toStringAsFixed(0) : null,
      postDate: (item['modificationTime'] is num)
          ? ((item['modificationTime'] as num).toInt() ~/ 1000).toString()
          : null,
      postDateFormat: (item['modificationTime'] is num) ? 'unix' : null,
      fileNameExtras: 'Eagle_',
    );
  }

  // ---- "send to library" (Phase 3: add/upload) -----------------------------

  @override
  bool get hasItemAddSupport => true;

  @override
  bool get hasItemAddFolders => true;

  /// Destination folders for the send UI: the full library tree flattened into
  /// indented `Parent / Child` labels (loading it first if needed).
  @override
  Future<List<({String id, String label})>> addTargetFolders() async {
    await loadFolders();
    final List<({String id, String label})> out = [];
    void walk(List<EagleFolder> folders, int depth) {
      for (final f in folders) {
        out.add((id: f.id, label: '${'    ' * depth}${f.name}'));
        if (f.children.isNotEmpty) {
          walk(f.children, depth + 1);
        }
      }
    }

    walk(_folderTree, 0);
    return out;
  }

  /// Push an item into Eagle via `/api/item/addFromURL`. The booru this item
  /// came from must expose a publicly fetchable [BooruItem.fileURL] (Eagle's
  /// desktop downloads it itself). [folderId] files it into a library folder.
  @override
  Future<bool> addItem(
    BooruItem item, {
    bool usePostUrl = false,
    String? folderId,
  }) async {
    final String downloadUrl = usePostUrl && item.postURL.isNotEmpty ? item.postURL : item.fileURL;
    if (downloadUrl.isEmpty) {
      return false;
    }
    try {
      final response = await DioNetwork.post(
        _withToken('${booru.baseURL}/api/item/addFromURL'),
        headers: {
          ...getHeaders(),
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        data: {
          'url': downloadUrl,
          'name': _addItemName(item, downloadUrl),
          if (item.postURL.isNotEmpty) 'website': item.postURL,
          'tags': item.tagsList.map((t) => t.fullString).toList(),
          if (item.description?.isNotEmpty == true) 'annotation': item.description,
          'folderId': ?folderId,
        },
      );
      if (response.statusCode != 200) {
        return false;
      }
      final Map<String, dynamic> data = response.data is String ? jsonDecode(response.data) : response.data;
      return data['status'] == 'success';
    } catch (e, s) {
      Logger.Inst().log(e.toString(), 'EagleHandler', 'addItem', LogTypes.exception, s: s);
      return false;
    }
  }

  /// Pick a human-friendly name for an added item: the source booru's id, else
  /// the URL's last path segment (without extension — Eagle infers that).
  String _addItemName(BooruItem item, String url) {
    final String? sid = item.serverId;
    if (sid != null && sid.isNotEmpty) {
      return sid;
    }
    try {
      final String last = Uri.parse(url).pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      final int dot = last.lastIndexOf('.');
      return dot > 0 ? last.substring(0, dot) : (last.isNotEmpty ? last : 'item');
    } catch (_) {
      return 'item';
    }
  }

  @override
  List<String> searchModifiers() => [
    'folder:',
    'ext:',
    'type:image',
    'type:video',
    'type:gif',
    'type:audio',
    'keyword:',
    'order:date',
    'order:name',
    'order:size',
    'order:resolution',
    'order:rating',
    'order:duration',
    'order:random',
  ];
}

class _EagleQuery {
  const _EagleQuery({
    required this.keyword,
    required this.tags,
    required this.folders,
    required this.ext,
    required this.orderBy,
    required this.typeExts,
  });

  final String keyword;
  final List<String> tags;
  final List<String> folders;
  final String? ext;
  final String? orderBy;
  final Set<String>? typeExts;
}

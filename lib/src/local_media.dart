import 'package:flutter/services.dart';

/// 用户选中的本地文件夹。
class PickedFolder {
  const PickedFolder({required this.uri, required this.name});

  final String uri;
  final String name;
}

/// SAF 树里的一个视频文件。
class LocalVideo {
  const LocalVideo({
    required this.uri,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.lastModified,
    required this.relativePath,
  });

  factory LocalVideo.fromMap(Map<Object?, Object?> map) => LocalVideo(
    uri: map['uri'] as String? ?? '',
    name: map['name'] as String? ?? '视频',
    size: (map['size'] as num?)?.toInt() ?? 0,
    mimeType: map['mimeType'] as String? ?? 'video/*',
    lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
    relativePath: map['relativePath'] as String? ?? '',
  );

  final String uri;
  final String name;
  final int size;
  final String mimeType;
  final int lastModified;
  final String relativePath;

  /// 缩略图缓存键：文件被替换后 mtime 变化，键自然失效。
  String get cacheKey => '$uri|$lastModified';

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
  }
}

/// 缩略图 + 时长。缩略图给的是磁盘缓存路径，交给 Flutter 自己的图片缓存去解码，
/// 避免每个条目都把几十 KB 的字节穿过平台通道。
class LocalThumbnail {
  const LocalThumbnail({required this.path, required this.durationMs});

  final String path;
  final int durationMs;
}

/// 一条播放记录。
class PlaybackEntry {
  const PlaybackEntry({
    required this.uri,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    required this.title,
  });

  factory PlaybackEntry.fromMap(Map<Object?, Object?> map) => PlaybackEntry(
    uri: map['uri'] as String? ?? '',
    positionMs: (map['position'] as num?)?.toInt() ?? 0,
    durationMs: (map['duration'] as num?)?.toInt() ?? 0,
    updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
    title: map['title'] as String? ?? '',
  );

  final String uri;
  final int positionMs;
  final int durationMs;
  final int updatedAt;
  final String title;

  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  bool get isFinished => durationMs > 0 && positionMs >= durationMs - 5000;

  int get remainingMs => durationMs > positionMs ? durationMs - positionMs : 0;
}

class LocalMediaBridge {
  LocalMediaBridge._();

  static final LocalMediaBridge instance = LocalMediaBridge._();
  static const _methods = MethodChannel('axplayer/methods');

  /// 缩略图内存缓存：同一个文件在整次会话里只解码一次。
  /// 磁盘缓存由原生侧负责，重启后依然命中。
  final Map<String, Future<LocalThumbnail?>> _thumbnails = {};

  Future<PickedFolder?> pickFolder() async {
    final map = await _methods.invokeMapMethod<String, Object?>(
      'pickLocalFolder',
    );
    if (map == null) return null;
    final uri = map['uri'] as String? ?? '';
    if (uri.isEmpty) return null;
    return PickedFolder(uri: uri, name: map['name'] as String? ?? '本地文件夹');
  }

  Future<List<LocalVideo>> listVideos(String treeUri) async {
    final raw =
        await _methods.invokeListMethod<Object?>('listLocalVideos', {
          'treeUri': treeUri,
        }) ??
        const [];
    return raw
        .map(
          (item) =>
              LocalVideo.fromMap(Map<Object?, Object?>.from(item! as Map)),
        )
        .where((video) => video.uri.isNotEmpty)
        .toList();
  }

  Future<LocalThumbnail?> thumbnail(LocalVideo video) =>
      thumbnailForUri(video.uri, lastModified: video.lastModified);

  /// 原生侧按 uri 缓存缩略图（修改时间记在伴生文件里），所以这里也按 uri 记忆，
  /// 同一个文件不管从网格还是从播放历史打开，都只请求一次。
  Future<LocalThumbnail?> thumbnailForUri(String uri, {int lastModified = 0}) {
    return _thumbnails.putIfAbsent(uri, () async {
      final map = await _methods.invokeMapMethod<String, Object?>(
        'getLocalVideoThumbnail',
        {'uri': uri, 'lastModified': lastModified},
      );
      final path = map?['path'] as String?;
      if (path == null || path.isEmpty) return null;
      return LocalThumbnail(
        path: path,
        durationMs: (map?['durationMs'] as num?)?.toInt() ?? 0,
      );
    });
  }

  void forgetThumbnail(LocalVideo video) => _thumbnails.remove(video.uri);

  Future<void> play(LocalVideo video) {
    return _methods.invokeMethod('openLocalVideo', {
      'uri': video.uri,
      'title': video.name,
    });
  }

  /// 以整份列表打开播放器，这样播放器内的上一个/下一个可以直接用。
  Future<void> playPlaylist(List<LocalVideo> videos, int index) {
    return _methods.invokeMethod('openLocalVideo', {
      'uris': videos.map((video) => video.uri).toList(),
      'titles': videos.map((video) => video.name).toList(),
      'index': index.clamp(0, videos.isEmpty ? 0 : videos.length - 1),
    });
  }

  /// 历史记录只保留了 uri 和标题，直接按 uri 播放。
  Future<void> playUri(String uri, String title) {
    return _methods.invokeMethod('openLocalVideo', {
      'uri': uri,
      'title': title,
    });
  }

  Future<Map<String, PlaybackEntry>> playbackHistory() async {
    final raw =
        await _methods.invokeMapMethod<String, Object?>('getPlaybackHistory') ??
        const {};
    final entries = <String, PlaybackEntry>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final parsed = PlaybackEntry.fromMap(Map<Object?, Object?>.from(value));
      if (parsed.uri.isEmpty) continue;
      entries[parsed.uri] = parsed;
    }
    return entries;
  }

  Future<void> forgetPlayback(List<String> uris) {
    if (uris.isEmpty) return Future.value();
    return _methods.invokeMethod('forgetPlaybackProgress', {'uris': uris});
  }
}

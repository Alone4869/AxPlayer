import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'download_bridge.dart';

class VideoThumbnail extends StatefulWidget {
  const VideoThumbnail({
    super.key,
    required this.task,
    required this.fallbackColor,
  });

  final DownloadTask task;
  final Color fallbackColor;

  @override
  State<VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<VideoThumbnail> {
  static final Map<String, Future<Uint8List?>> _cache = {};
  late Future<Uint8List?> _thumbnail;

  String get _cacheKey => widget.task.contentUri.isNotEmpty
      ? widget.task.contentUri
      : '${widget.task.id}:${widget.task.fileSize}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey = oldWidget.task.contentUri.isNotEmpty
        ? oldWidget.task.contentUri
        : '${oldWidget.task.id}:${oldWidget.task.fileSize}';
    if (oldKey != _cacheKey) _load();
  }

  void _load() {
    _thumbnail = _cache.putIfAbsent(
      _cacheKey,
      () => DownloadBridge.instance
          .getVideoThumbnail(widget.task)
          .catchError((_) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: FutureBuilder<Uint8List?>(
          future: _thumbnail,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) {
              return VideoThumbnailFallback(color: widget.fallbackColor);
            }
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) =>
                  VideoThumbnailFallback(color: widget.fallbackColor),
            );
          },
        ),
      ),
    );
  }
}

class VideoThumbnailFallback extends StatelessWidget {
  const VideoThumbnailFallback({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color.withAlpha(38),
      child: Icon(Icons.movie_creation_outlined, color: color, size: 24),
    );
  }
}

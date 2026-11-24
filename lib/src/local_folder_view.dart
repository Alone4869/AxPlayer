import 'package:flutter/material.dart';

import 'file_size.dart';
import 'glass_surface.dart';
import 'local_media.dart';
import 'playback_history_view.dart';
import 'server_settings.dart';

enum _SortMode { name, recent, size }

enum _MenuAction { refresh, changeFolder }

/// 本地文件夹浏览页。
///
/// 数据全部来自 SAF 树 URI，不依赖 MediaStore——用户选中哪个文件夹就看哪个，
/// 不受系统媒体库收录范围限制。
class LocalFolderView extends StatefulWidget {
  const LocalFolderView({
    super.key,
    required this.config,
    this.bridge,
    this.onConfigChanged,
  });

  final ServerConfig config;
  final LocalMediaBridge? bridge;
  final ValueChanged<ServerConfig>? onConfigChanged;

  @override
  State<LocalFolderView> createState() => _LocalFolderViewState();
}

class _LocalFolderViewState extends State<LocalFolderView>
    with WidgetsBindingObserver {
  late final LocalMediaBridge _bridge;
  late ServerConfig _config;
  List<LocalVideo> _videos = const [];
  Map<String, PlaybackEntry> _history = const {};
  bool _loading = true;
  String? _error;
  _SortMode _sort = _SortMode.name;
  bool _refreshOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bridge = widget.bridge ?? LocalMediaBridge.instance;
    _config = widget.config;
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从播放器返回时刷新进度，让"继续观看"立刻反映刚才看到的位置
    if (state == AppLifecycleState.resumed && _refreshOnResume) {
      _refreshOnResume = false;
      _refreshHistory();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final videos = await _bridge.listVideos(_config.url);
      final history = await _bridge.playbackHistory();
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _history = history;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _refreshHistory() async {
    try {
      final history = await _bridge.playbackHistory();
      if (!mounted) return;
      setState(() => _history = history);
    } catch (_) {
      // 进度只是锦上添花，读不到就维持原样
    }
  }

  Future<void> _play(LocalVideo video) async {
    _refreshOnResume = true;
    try {
      // 以当前排序后的完整列表打开，播放器里就能直接切上一个/下一个
      final playlist = _sortedVideos;
      final index = playlist.indexWhere((item) => item.uri == video.uri);
      await _bridge.playPlaylist(playlist, index < 0 ? 0 : index);
    } catch (error) {
      _refreshOnResume = false;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法播放：$error')));
    }
  }

  Future<void> _openHistory() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => PlaybackHistoryView(bridge: _bridge)),
    );
    if (!mounted) return;
    // 历史页里可能重看过某些视频，回来同步一次进度
    await _refreshHistory();
  }

  Future<void> _changeFolder() async {
    final picked = await _bridge.pickFolder();
    if (picked == null || !mounted) return;
    final updated = ServerConfig(
      id: _config.id,
      type: ServerType.local,
      name: picked.name,
      url: picked.uri,
      createdAt: _config.createdAt,
    );
    widget.onConfigChanged?.call(updated);
    setState(() {
      _config = updated;
      _videos = const [];
      _history = const {};
    });
    await _load();
  }

  List<LocalVideo> get _sortedVideos {
    final list = [..._videos];
    switch (_sort) {
      case _SortMode.name:
        list.sort(
          (a, b) => a.relativePath.toLowerCase().compareTo(
            b.relativePath.toLowerCase(),
          ),
        );
      case _SortMode.recent:
        list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      case _SortMode.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }
    return list;
  }

  List<LocalVideo> get _continueWatching {
    final playing = _videos.where((video) {
      final entry = _history[video.uri];
      if (entry == null || entry.isFinished) return false;
      // 刚点开就退出不算"看到一半"
      return entry.positionMs >= 15000;
    }).toList();
    playing.sort((a, b) {
      final left = _history[a.uri]?.updatedAt ?? 0;
      final right = _history[b.uri]?.updatedAt ?? 0;
      return right.compareTo(left);
    });
    return playing.take(10).toList();
  }

  int get _totalSize => _videos.fold(0, (sum, video) => sum + video.size);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: CustomScrollView(
          slivers: [
            _buildAppBar(),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _ErrorState(
                  message: _error!,
                  onRetry: _load,
                  onChangeFolder: _changeFolder,
                ),
              )
            else if (_videos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(
                  onChangeFolder: _changeFolder,
                  onRefresh: _load,
                ),
              )
            else ...[
              if (_continueWatching.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _ContinueWatching(
                    videos: _continueWatching,
                    history: _history,
                    onTap: _play,
                    bridge: _bridge,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 4)),
              ],
              _SectionTitle(title: '全部视频', trailing: '${_videos.length} 个'),
              _buildGrid(),
              const SliverToBoxAdapter(child: SizedBox(height: 108)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    final colors = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 168,
      backgroundColor: colors.surface.withValues(alpha: 0.94),
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actions: [
        IconButton(
          tooltip: '播放历史',
          onPressed: _openHistory,
          icon: const Icon(Icons.history_rounded),
        ),
        PopupMenuButton<_SortMode>(
          tooltip: '排序',
          icon: const Icon(Icons.sort_rounded),
          initialValue: _sort,
          onSelected: (mode) => setState(() => _sort = mode),
          itemBuilder: (context) => const [
            PopupMenuItem(value: _SortMode.name, child: Text('按名称')),
            PopupMenuItem(value: _SortMode.recent, child: Text('按修改时间')),
            PopupMenuItem(value: _SortMode.size, child: Text('按大小')),
          ],
        ),
        PopupMenuButton<_MenuAction>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (action) {
            switch (action) {
              case _MenuAction.refresh:
                _load();
              case _MenuAction.changeFolder:
                _changeFolder();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _MenuAction.refresh,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.refresh_rounded),
                title: Text('重新扫描'),
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.changeFolder,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.drive_folder_upload_outlined),
                title: Text('更换文件夹'),
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14),
        title: Text(
          _config.name.isEmpty ? '本地文件夹' : _config.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
        background: _HeaderDecoration(
          count: _videos.length,
          totalSize: _totalSize,
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = width >= 860
            ? 4
            : width >= 620
            ? 3
            : 2;
        const spacing = 14.0;
        const horizontalPadding = 16.0;
        final tileWidth =
            (width - horizontalPadding * 2 - spacing * (columns - 1)) / columns;
        final tileHeight = tileWidth * 9 / 16 + 58;
        final videos = _sortedVideos;
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              mainAxisExtent: tileHeight,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final video = videos[index];
              return _VideoTile(
                video: video,
                entry: _history[video.uri],
                onTap: () => _play(video),
                bridge: _bridge,
              );
            }, childCount: videos.length),
          ),
        );
      },
    );
  }
}

/// 顶部展开区的装饰：一块柔和的主色渐变，避免纯色背景显得空。
class _HeaderDecoration extends StatelessWidget {
  const _HeaderDecoration({required this.count, required this.totalSize});

  final int count;
  final int totalSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.primary.withValues(alpha: 0.18),
                colors.primary.withValues(alpha: 0.02),
              ],
            ),
          ),
        ),
        Positioned(
          right: -30,
          top: -20,
          child: Icon(
            Icons.video_library_rounded,
            size: 150,
            color: colors.primary.withValues(alpha: 0.07),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 58,
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: colors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$count 个视频 · ${formatFileSize(totalSize)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
        child: Row(
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 继续观看：横向卡片，带进度与剩余时长。
class _ContinueWatching extends StatelessWidget {
  const _ContinueWatching({
    required this.videos,
    required this.history,
    required this.onTap,
    required this.bridge,
  });

  final List<LocalVideo> videos;
  final Map<String, PlaybackEntry> history;
  final ValueChanged<LocalVideo> onTap;
  final LocalMediaBridge bridge;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Row(
            children: [
              Icon(
                Icons.play_circle_fill_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '继续观看',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        SizedBox(
          // 16:9 封面（258 宽约 145 高）+ 上下内边距 + 两行文字，留一点余量
          height: 204,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: videos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final video = videos[index];
              return _ContinueCard(
                video: video,
                entry: history[video.uri]!,
                onTap: () => onTap(video),
                bridge: bridge,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.video,
    required this.entry,
    required this.onTap,
    required this.bridge,
  });

  final LocalVideo video;
  final PlaybackEntry entry;
  final VoidCallback onTap;
  final LocalMediaBridge bridge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 258,
      child: AppSurface(
        borderRadius: 20,
        elevated: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _Thumbnail(
                      video: video,
                      borderRadius: 0,
                      bridge: bridge,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(20),
                      ),
                      child: LinearProgressIndicator(
                        value: entry.progress,
                        minHeight: 3.5,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        valueColor: AlwaysStoppedAnimation(colors.primary),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 9,
                    child: _Pill(
                      icon: Icons.timelapse_rounded,
                      label: '还剩 ${_formatDuration(entry.remainingMs)}',
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(entry.progress * 100).round()}% · ${formatFileSize(video.size)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.video,
    required this.entry,
    required this.onTap,
    required this.bridge,
  });

  final LocalVideo video;
  final PlaybackEntry? entry;
  final VoidCallback onTap;
  final LocalMediaBridge bridge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = entry == null || entry!.isFinished
        ? null
        : entry!.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Thumbnail(video: video, borderRadius: 16, bridge: bridge),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        valueColor: AlwaysStoppedAnimation(colors.primary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                video.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${formatFileSize(video.size)}${video.extension.isEmpty ? '' : ' · ${video.extension}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 缩略图。内存缓存由 [LocalMediaBridge] 负责，磁盘缓存由原生侧负责，
/// 所以这里翻来覆去 build 也不会重复解码。
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.video,
    required this.borderRadius,
    required this.bridge,
  });

  final LocalVideo video;
  final double borderRadius;
  final LocalMediaBridge bridge;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Future<LocalThumbnail?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.bridge.thumbnail(widget.video);
  }

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.cacheKey != widget.video.cacheKey) {
      _future = widget.bridge.thumbnail(widget.video);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(widget.borderRadius);
    return ClipRRect(
      borderRadius: radius,
      child: FutureBuilder<LocalThumbnail?>(
        future: _future,
        builder: (context, snapshot) {
          final thumb = snapshot.data;
          if (thumb == null) {
            return ColoredBox(
              color: colors.surfaceContainerHighest,
              child: Center(
                child: Icon(
                  Icons.movie_creation_outlined,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                  size: 26,
                ),
              ),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                thumb.bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
              if (thumb.durationMs > 0)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: _Pill(label: _formatDuration(thumb.durationMs)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onChangeFolder, required this.onRefresh});

  final VoidCallback onChangeFolder;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(
                Icons.video_library_outlined,
                size: 38,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '这个文件夹里没有视频',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '支持 mp4、mkv、webm、mov、ts 等常见格式，子文件夹也会一起扫描',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新扫描'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onChangeFolder,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('换个文件夹'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    required this.onChangeFolder,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onChangeFolder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(
                Icons.folder_off_outlined,
                size: 38,
                color: colors.onErrorContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '读不到这个文件夹',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '可能是授权已失效，重新选一次文件夹即可。\n$message',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                height: 1.5,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onChangeFolder,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('重新选择'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '00:00';
  final totalSeconds = milliseconds ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

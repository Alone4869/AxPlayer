import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'local_media.dart';

/// 播放历史。
///
/// 数据来自原生侧按 uri 记录的最后播放位置，全局共享（不区分是哪个文件夹），
/// 这里只取最近 50 条。缩略图沿用同一个磁盘缓存。
class PlaybackHistoryView extends StatefulWidget {
  const PlaybackHistoryView({super.key, this.bridge});

  final LocalMediaBridge? bridge;

  @override
  State<PlaybackHistoryView> createState() => _PlaybackHistoryViewState();
}

class _PlaybackHistoryViewState extends State<PlaybackHistoryView>
    with WidgetsBindingObserver {
  static const _limit = 50;

  late final LocalMediaBridge _bridge;
  List<PlaybackEntry> _entries = const [];
  bool _loading = true;
  bool _refreshOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bridge = widget.bridge ?? LocalMediaBridge.instance;
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _refreshOnResume) {
      _refreshOnResume = false;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final history = await _bridge.playbackHistory();
      final sorted = history.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _entries = sorted.take(_limit).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _play(PlaybackEntry entry) async {
    _refreshOnResume = true;
    try {
      await _bridge.playUri(entry.uri, entry.title);
    } catch (error) {
      _refreshOnResume = false;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法播放：$error')));
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空播放历史？'),
        content: const Text('只删除观看记录，视频文件不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _bridge.forgetPlayback(_entries.map((entry) => entry.uri).toList());
    if (!mounted) return;
    setState(() => _entries = const []);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 132,
              backgroundColor: colors.surface.withValues(alpha: 0.94),
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              actions: [
                if (_entries.isNotEmpty)
                  IconButton(
                    tooltip: '清空历史',
                    onPressed: _clearAll,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                const SizedBox(width: 4),
              ],
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsetsDirectional.only(
                  start: 56,
                  bottom: 14,
                ),
                title: const Text(
                  '播放历史',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colors.primary.withValues(alpha: 0.16),
                        colors.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 74, 20, 0),
                    child: Row(
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _loading ? '正在读取…' : '最近 ${_entries.length} 条',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_entries.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyHistory(),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                sliver: SliverList.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _HistoryTile(
                    entry: _entries[index],
                    bridge: _bridge,
                    onTap: () => _play(_entries[index]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.bridge,
    required this.onTap,
  });

  final PlaybackEntry entry;
  final LocalMediaBridge bridge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = entry.title.isEmpty ? _nameOf(entry.uri) : entry.title;
    return AppSurface(
      borderRadius: 18,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              _HistoryThumbnail(uri: entry.uri, bridge: bridge),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: entry.progress,
                        minHeight: 3,
                        backgroundColor: colors.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation(colors.primary),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _subtitle(entry),
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
              const SizedBox(width: 8),
              Icon(Icons.play_arrow_rounded, color: colors.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  static String _nameOf(String uri) {
    final decoded = Uri.decodeComponent(uri);
    final slash = decoded.lastIndexOf('/');
    return slash < 0 ? decoded : decoded.substring(slash + 1);
  }

  static String _subtitle(PlaybackEntry entry) {
    final parts = <String>[];
    if (entry.durationMs > 0) {
      parts.add('还剩 ${_formatDuration(entry.remainingMs)}');
    }
    if (entry.updatedAt > 0) {
      parts.add(_relativeTime(entry.updatedAt));
    }
    return parts.isEmpty ? '最近播放' : parts.join(' · ');
  }
}

class _HistoryThumbnail extends StatelessWidget {
  const _HistoryThumbnail({required this.uri, required this.bridge});

  final String uri;
  final LocalMediaBridge bridge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      height: 54,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FutureBuilder<LocalThumbnail?>(
          future: bridge.thumbnailForUri(uri),
          builder: (context, snapshot) {
            final thumb = snapshot.data;
            if (thumb == null) {
              return ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Icon(
                  Icons.movie_creation_outlined,
                  size: 20,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              );
            }
            return Image.memory(
              thumb.bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            );
          },
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

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
              width: 82,
              height: 82,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(
                Icons.history_rounded,
                size: 36,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '还没有播放记录',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '看过的本地视频会出现在这里，方便接着上次的位置继续',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
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

String _relativeTime(int epochMillis) {
  final played = DateTime.fromMillisecondsSinceEpoch(epochMillis);
  final now = DateTime.now();
  final diff = now.difference(played);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${played.year}-${played.month.toString().padLeft(2, '0')}-${played.day.toString().padLeft(2, '0')}';
}

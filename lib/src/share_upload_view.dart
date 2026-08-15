import 'package:flutter/material.dart';

import 'download_bridge.dart';
import 'file_size.dart';
import 'glass_surface.dart';
import 'smb_upload.dart';
import 'video_thumbnail.dart';

class ShareUploadView extends StatefulWidget {
  const ShareUploadView({super.key, required this.files});

  final List<SmbPickedFile> files;

  @override
  State<ShareUploadView> createState() => _ShareUploadViewState();
}

class _ShareUploadViewState extends State<ShareUploadView> {
  late final List<SmbPickedFile> _files = [...widget.files];

  void _removeAt(int index) {
    setState(() => _files.removeAt(index));
  }

  Future<void> _upload() async {
    await uploadPickedVideosToSmb(context, _files);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final canUpload = _files.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('分享到 SMB')),
      body: Column(
        children: [
          Expanded(
            child: _files.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _SharedFileTile(
                      file: _files[index],
                      color: color,
                      onRemove: () => _removeAt(index),
                    ),
                  ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canUpload ? _upload : null,
                icon: const Icon(Icons.cloud_upload),
                label: Text(canUpload ? '上传到 SMB' : '没有可上传的视频'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SharedFileTile extends StatelessWidget {
  const _SharedFileTile({
    required this.file,
    required this.color,
    required this.onRemove,
  });

  final SmbPickedFile file;
  final Color color;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final task = DownloadTask(
      id: '',
      url: '',
      fileName: file.name,
      status: DownloadStatus.completed,
      progress: 1,
      contentUri: file.uri,
      fileSize: file.size,
    );
    return AppSurface(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          VideoThumbnail(task: task, fallbackColor: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatFileSize(file.size),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

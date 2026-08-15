# 分享视频上传到 SMB 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户从系统文件管理器/相册多选视频分享到本 app，展示确认页后可批量上传到已配置的 SMB 共享目录。

**Architecture:** 用 `MainActivity` 声明 `ACTION_SEND`/`ACTION_SEND_MULTIPLE` + `video/*` 分享目标，原生侧在 `onCreate`/`onNewIntent` 解析分享 Intent 并缓存 content URI 元数据；Flutter 通过新 MethodChannel 方法 `consumeSharedVideos` 一次性取走列表，`HomeScreen.initState` 触发并 push 全新的 `ShareUploadView` 确认页（可移除项、上传按钮）；上传复用现有 SMB 管道。

**Tech Stack:** Android (FlutterActivity / share intent / SAF content URIs)、Flutter (Dart)、jcifs-ng SMB 上传（现有）。

## Global Constraints

- 不引入任何第三方依赖（Dart 侧仅现有依赖，Kotlin 侧仅 Android SDK）。
- 原生方法走 MethodChannel `m3u8_downloader/methods`；上传进度走 `m3u8_downloader/upload_events`。
- 分享 URI 是临时读授权，**不得**调用 `takePersistableUriPermission`。
- UI 文案简体中文；确认页标题「分享到 SMB」，按钮「上传到 SMB」。
- `minSdk = 29`；Kotlin 编译需 `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`。
- 分享确认页为全屏页面（`ShareUploadView`），原生不导航；移除逻辑在 Flutter State 中。
- `_video_thumbnail` 相关私有类跨文件复用需提取为公共 `VideoThumbnail`。

---

### Task 1: 声明分享目标并原生接收分享 Intent

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`（MainActivity 增加 intent-filter）
- Modify: `android/app/src/main/kotlin/io/github/alone4869/m3u8downloader/MainActivity.kt`
- 验证：`./gradlew :app:compileDebugKotlin`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - MethodChannel 方法 `consumeSharedVideos` → `result.success(List<Map<String, Any>>)`（`uri`/`name`/`size`，无则为空列表）
  - AndroidManifest 中 `MainActivity` 的分享 `<intent-filter>`
  - MainActivity 重写 `onCreate` / `onNewIntent` 解析分享 Intent 并填充 `pendingSharedFiles`

- [ ] **Step 1: AndroidManifest 增加分享 intent-filter**

在 `MainActivity` 的现有 `</intent-filter>`（MAIN/LAUNCHER，第 39-42 行）之后、`</activity>` 之前加入：

```xml
<intent-filter>
    <action android:name="android.intent.action.SEND" />
    <action android:name="android.intent.action.SEND_MULTIPLE" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:mimeType="video/*" />
</intent-filter>
```

预期：Manifest 语法无误。

- [ ] **Step 2: MainActivity 新增字段与常量**

在 `MainActivity.kt` 第 30 行 `private var pendingPickerResult: MethodChannel.Result? = null` 之后新增：

```kotlin
private var pendingSharedFiles: List<Map<String, Any>>? = null
```

在 companion object（第 499-500 行附近）`PICK_FILES_REQUEST` 之后新增常量：

```kotlin
private const val SHARE_SEND = Intent.ACTION_SEND
private const val SHARE_SEND_MULTIPLE = Intent.ACTION_SEND_MULTIPLE
```

在文件顶部 import 区（第 8 行 `android.net.Uri` 附近）新增：

```kotlin
import android.os.Bundle
import android.os.Parcelable
```

- [ ] **Step 3: 重写 onCreate 与 onNewIntent 解析分享 Intent**

在 `configureFlutterEngine`（第 39 行）之前新增：

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    consumeShareIntent(intent)
}

override fun onNewIntent(intent: Intent?) {
    super.onNewIntent(intent)
    setIntent(intent)
    consumeShareIntent(intent)
}
```

在 `onRequestPermissionsResult`（第 355 行）之后新增解析函数：

```kotlin
private fun consumeShareIntent(intent: Intent?) {
    val action = intent?.action
    if (action != SHARE_SEND && action != SHARE_SEND_MULTIPLE) return
    val uris = buildList {
        intent.clipData?.let { clip ->
            repeat(clip.itemCount) { index -> add(clip.getItemAt(index).uri) }
        }
        if (isEmpty()) {
            val streamList = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            }
            if (streamList != null) streamList.forEach { uri -> if (uri != null) add(uri) }
        }
        if (isEmpty()) {
            val single: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            if (single != null) add(single)
        }
        if (isEmpty()) intent.data?.let { add(it) }
    }
    if (uris.isEmpty()) return
    pendingSharedFiles = uris.mapNotNull { uri ->
        runCatching {
            mapOf(
                "uri" to uri.toString(),
                "name" to runCatching {
                    queryDisplayName(uri)
                }.getOrElse { fallbackDisplayName(uri) },
                "size" to runCatching { queryFileSize(uri) }.getOrDefault(0L),
            )
        }.getOrNull()
    }
}
```

- [ ] **Step 4: MethodChannel 新增 `consumeSharedVideos` 分支**

在 `"pickSmbFiles" -> { ... }` 分支（第 231-250 行）结束之后、`"uploadToSmb" -> {`（第 251 行）之前加入：

```kotlin
"consumeSharedVideos" -> {
    val files = pendingSharedFiles
    pendingSharedFiles = null
    result.success(files ?: emptyList<Map<String, Any>>())
}
```

预期：跨冷/热启动，分享后 `consumeSharedVideos` 一次性返回缓存内容并清空；二次调用返回空列表。

- [ ] **Step 5: Kotlin 编译验证**

运行：

```bash
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:compileDebugKotlin
```

预期：`BUILD SUCCESSFUL`（工作目录 `android/`）。

- [ ] **Step 6: 提交**

```bash
git add android/app/src/main/AndroidManifest.xml \
  android/app/src/main/kotlin/io/github/alone4869/m3u8downloader/MainActivity.kt
git commit -m "feat: receive shared videos as an SMB upload source"
```

---

### Task 2: Flutter 桥 `consumeSharedVideos`

**Files:**
- Modify: `lib/src/download_bridge.dart`（新增方法）
- Test: `test/download_task_test.dart`

**Interfaces:**
- Consumes: Task 1 的 MethodChannel 方法 `consumeSharedVideos`（返回 `List<Map>` of `{uri,name,size}` 或空）
- Produces: `Future<List<SmbPickedFile>> DownloadBridge.consumeSharedVideos()`

- [ ] **Step 1: 写失败测试**

在 `test/download_task_test.dart` 末尾（`pickSmbFiles` 测试之后）新增：

```dart
  test('consumes shared videos from the native share target', () async {
    const channel = MethodChannel('m3u8_downloader/methods');
    MethodCall? capturedCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      capturedCall = call;
      return [
        {'uri': 'content://share/1', 'name': 'shared.mp4', 'size': 2097152},
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final files = await DownloadBridge.instance.consumeSharedVideos();

    expect(capturedCall?.method, 'consumeSharedVideos');
    expect(files, hasLength(1));
    expect(files.first.name, 'shared.mp4');
    expect(files.first.size, 2097152);
  });

  test('returns an empty list when nothing was shared', () async {
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => []);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final files = await DownloadBridge.instance.consumeSharedVideos();

    expect(files, isEmpty);
  });
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/download_task_test.dart
```

预期：`consumeSharedVideos` 编译错误（未定义）。

- [ ] **Step 3: 实现 `consumeSharedVideos`**

在 `lib/src/download_bridge.dart` 的 `pickSmbFiles()`（第 241-250 行）之后新增：

```dart
  Future<List<SmbPickedFile>> consumeSharedVideos() async {
    final raw =
        await _methods.invokeListMethod<Object?>('consumeSharedVideos') ??
        const [];
    return raw
        .map(
          (item) =>
              SmbPickedFile.fromMap(Map<Object?, Object?>.from(item! as Map)),
        )
        .toList();
  }
```

- [ ] **Step 4: 运行测试确认通过**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/download_task_test.dart
```

预期：全部通过（含原有测试）。

- [ ] **Step 5: 提交**

```bash
git add lib/src/download_bridge.dart test/download_task_test.dart
git commit -m "feat: bridge consume of shared videos"
```

---

### Task 3: 提取公共 `VideoThumbnail` 组件

**Files:**
- Create: `lib/src/video_thumbnail.dart`
- Modify: `lib/src/app.dart`（删除私有类、改用公共组件；app.dart:2008-2091）
- Test: `test/video_thumbnail_test.dart`（新建）
- 验证：`flutter test`、`flutter analyze`

**Interfaces:**
- Consumes: `DownloadBridge.instance.getVideoThumbnail(DownloadTask)`（现有）、`DownloadTask`（现有）
- Produces: `Widget VideoThumbnail({required DownloadTask task, required Color fallbackColor})`、`Widget VideoThumbnailFallback({required Color color})`

- [ ] **Step 1: 写失败测试**

创建 `test/video_thumbnail_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/download_bridge.dart';
import 'package:m3u8downloader/src/video_thumbnail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('falls back to the movie icon when no thumbnail is available',
      (tester) async {
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const task = DownloadTask(
      id: '',
      url: '',
      fileName: 'clip.mp4',
      status: DownloadStatus.completed,
      progress: 1,
      contentUri: 'content://share/1',
      fileSize: 1024,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoThumbnail(task: task, fallbackColor: Colors.red),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.movie_creation_outlined), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/video_thumbnail_test.dart
```

预期：`video_thumbnail.dart` 找不到，编译失败。

- [ ] **Step 3: 创建 `video_thumbnail.dart`**

```dart
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
```

- [ ] **Step 4: 更新 app.dart 删除私有类**

删除 `lib/src/app.dart` 第 2008-2091 行的 `_VideoThumbnail`、`_VideoThumbnailState`、`_VideoThumbnailFallback` 三个类，并：

- 在文件顶部 import 区（第 14 行 `import 'smb_upload.dart';` 之后）新增 `import 'video_thumbnail.dart';`
- 将第 1590 行 `_VideoThumbnail(` 替换为 `VideoThumbnail(`

- [ ] **Step 5: 运行测试确认通过**

运行：

```bash
~/fvm/versions/stable/bin/flutter test
```

预期：全部通过。

- [ ] **Step 6: analyze 检查**

运行：

```bash
~/fvm/versions/stable/bin/flutter analyze
```

预期：无问题。

- [ ] **Step 7: 提交**

```bash
git add lib/src/video_thumbnail.dart lib/src/app.dart test/video_thumbnail_test.dart
git commit -m "refactor: extract public VideoThumbnail widget"
```

---

### Task 4: `smb_upload.dart` 提取 `uploadPickedVideosToSmb`

**Files:**
- Modify: `lib/src/smb_upload.dart`（128-158 行）
- Test: `test/smb_upload_test.dart`（新建）

**Interfaces:**
- Consumes: 现有私有 `_ensureConfiguredSmb`、`_SmbFolderPicker`、`_uploadTasksWithProgress`
- Produces:
  - `Future<void> uploadPickedVideosToSmb(BuildContext context, List<SmbPickedFile> files)`（空列表直接返回；否则走配置检查→目录选择→进度上传）
  - `uploadLocalVideosToSmb` 变为 pick 后委托调用 `uploadPickedVideosToSmb`（行为不变）

- [ ] **Step 1: 写失败测试**

创建 `test/smb_upload_test.dart`：

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/smb_upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uploading an empty picked list never touches the SMB channel',
      () async {
    const channel = MethodChannel('m3u8_downloader/methods');
    var uploadCalled = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'uploadToSmb') uploadCalled = true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await uploadPickedVideosToSmb(null, const []);

    expect(uploadCalled, isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/smb_upload_test.dart
```

预期：`uploadPickedVideosToSmb` 未定义，编译失败。

- [ ] **Step 3: 重构 `uploadLocalVideosToSmb` 并新增函数**

将 `lib/src/smb_upload.dart` 第 128-158 行的 `uploadLocalVideosToSmb` 整体替换为：

```dart
Future<void> uploadLocalVideosToSmb(BuildContext context) async {
  final List<SmbPickedFile> picked;
  try {
    picked = await DownloadBridge.instance.pickSmbFiles();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('选择视频失败：$error')));
    return;
  }
  if (!context.mounted) return;
  if (picked.isEmpty) return;
  await uploadPickedVideosToSmb(context, picked);
}

Future<void> uploadPickedVideosToSmb(
  BuildContext context,
  List<SmbPickedFile> files,
) async {
  if (files.isEmpty) return;
  final config = await _ensureConfiguredSmb(context);
  if (config == null || !context.mounted) return;

  final tasks = [
    for (final file in files)
      DownloadTask(
        id: '',
        url: '',
        fileName: file.name,
        status: DownloadStatus.completed,
        progress: 1,
        contentUri: file.uri,
        fileSize: file.size,
      ),
  ];
  await _uploadTasksWithProgress(context, config: config, tasks: tasks);
}
```

- [ ] **Step 4: 运行测试确认通过**

运行：

```bash
~/fvm/versions/stable/bin/flutter test
```

预期：全部通过（含新测试与原有 89 项）。

- [ ] **Step 5: 提交**

```bash
git add lib/src/smb_upload.dart test/smb_upload_test.dart
git commit -m "refactor: share upload against picked video files"
```

---

### Task 5: 「分享到 SMB」确认页 `ShareUploadView`

**Files:**
- Create: `lib/src/share_upload_view.dart`
- Test: `test/share_upload_view_test.dart`（新建）

**Interfaces:**
- Consumes: `SmbPickedFile`（download_bridge.dart）、`uploadPickedVideosToSmb`（Task 4）、`VideoThumbnail`（Task 3）、`AppSurface`（glass_surface.dart）
- Produces: `Widget ShareUploadView({required List<SmbPickedFile> files})` —— StatefulWidget，支持列表渲染、移除个别项、空列表禁用上传按钮

- [ ] **Step 1: 写失败测试**

创建 `test/share_upload_view_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/download_bridge.dart';
import 'package:m3u8downloader/src/share_upload_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(List<SmbPickedFile> files) =>
      MaterialApp(home: ShareUploadView(files: files));

  Future<void> mockChannel(MethodCall? Function() onCall) async {
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => onCall());
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  testWidgets('renders the shared video list', (tester) async {
    await mockChannel(() => null);

    await tester.pumpWidget(
      wrap(const [
        SmbPickedFile(uri: 'content://1', name: 'a.mp4', size: 1048576),
        SmbPickedFile(uri: 'content://2', name: 'b.mp4', size: 2097152),
      ]),
    );
    await tester.pump();

    expect(find.text('a.mp4'), findsOneWidget);
    expect(find.text('b.mp4'), findsOneWidget);
    expect(find.text('1.0 MB'), findsOneWidget);
    expect(find.text('上传到 SMB'), findsOneWidget);
  });

  testWidgets('removing the only item disables the upload button',
      (tester) async {
    await mockChannel(() => null);

    await tester.pumpWidget(
      wrap(const [
        SmbPickedFile(uri: 'content://1', name: 'a.mp4', size: 1024),
      ]),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('a.mp4'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    expect(button.onPressed, isNull);
    expect(find.text('没有可上传的视频'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/share_upload_view_test.dart
```

预期：`share_upload_view.dart` 不存在，编译失败。

- [ ] **Step 3: 创建 `share_upload_view.dart`**

```dart
import 'package:flutter/material.dart';

import 'download_bridge.dart';
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
                ? const Center(child: Text('没有要上传的视频'))
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
                  _formatSize(file.size),
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

String _formatSize(int bytes) {
  if (bytes <= 0) return '—';
  final megabytes = bytes / 1024 / 1024;
  if (megabytes < 1024) return '${megabytes.toStringAsFixed(1)} MB';
  return '${(megabytes / 1024).toStringAsFixed(2)} GB';
}
```

- [ ] **Step 4: 运行测试确认通过**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/share_upload_view_test.dart
```

预期：全部通过。

- [ ] **Step 5: 提交**

```bash
git add lib/src/share_upload_view.dart test/share_upload_view_test.dart
git commit -m "feat: add share-to-SMB confirmation page"
```

---

### Task 6: `HomeScreen` 触发分享上传确认页

**Files:**
- Modify: `lib/src/app.dart`（`_HomeScreenState`，第 173-362 行）
- Test: `test/share_trigger_test.dart`（新建）

**Interfaces:**
- Consumes: `DownloadBridge.instance.consumeSharedVideos()`（Task 2）、`ShareUploadView`（Task 5）
- Produces: 无（行为：`HomeScreen` 首次构建时消费分享内容，非空则 push 确认页；异常静默）

- [ ] **Step 1: 写失败测试**

创建 `test/share_trigger_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('consuming shared videos opens the share upload view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeSharedVideos') {
        return [
          {'uri': 'content://share/1', 'name': 'shared.mp4', 'size': 1048576},
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsOneWidget);
    expect(find.text('shared.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty share does not open the upload view', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('m3u8_downloader/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('分享到 SMB'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

运行：

```bash
~/fvm/versions/stable/bin/flutter test test/share_trigger_test.dart
```

预期：`分享到 SMB` 找不到（未实现触发）。

- [ ] **Step 3: 实现 `_HomeScreenState` 消费逻辑**

在 `_HomeScreenState` 中（第 174 行字段之后）新增：

```dart
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeSharedVideos());
  }

  Future<void> _consumeSharedVideos() async {
    final List<SmbPickedFile> shared;
    try {
      shared = await DownloadBridge.instance.consumeSharedVideos();
    } catch (_) {
      return;
    }
    if (!mounted || shared.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShareUploadView(files: shared),
      ),
    );
  }
```

在 `app.dart` 顶部 import 区（现有 `import 'share...'` 不存在，需新增）加入：

```dart
import 'share_upload_view.dart';
```

注意：`SmbPickedFile` 来自 `download_bridge.dart`（app.dart 已 import 该文件，第 10 行）。

- [ ] **Step 4: 运行测试确认通过**

运行：

```bash
~/fvm/versions/stable/bin/flutter test
```

预期：全部通过（含新 2 项、server_tab_test 等原有全部）。

- [ ] **Step 5: analyze 检查**

运行：

```bash
~/fvm/versions/stable/bin/flutter analyze
```

预期：无问题。

- [ ] **Step 6: 提交**

```bash
git add lib/src/app.dart test/share_trigger_test.dart
git commit -m "feat: open share upload page when videos are received"
```

---

## 收尾验证

完成后运行完整回归：

```bash
~/fvm/versions/stable/bin/flutter test
~/fvm/versions/stable/bin/flutter analyze
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:compileDebugKotlin
```

预期：三处全绿。

**手动验证清单（真机）**

- [ ] 相册多选视频 → 分享 → 选择本 app → 出现确认页，列表含缩略图/名称/大小
- [ ] 冷启动路径（app 未运行）与热启动路径（app 在后台）各验证一次
- [ ] 移除个别项后数量减少；全部移除后按钮禁用变灰
- [ ] 未配置 SMB 时点「上传到 SMB」弹「尚未配置 SMB」
- [ ] 配置后进入目录选择 → 上传进度对话框 → 「已上传 N 个文件」
- [ ] 普通启动（非分享）app 正常进入首页，无确认页弹出
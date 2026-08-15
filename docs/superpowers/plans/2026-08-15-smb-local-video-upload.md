# SMB 上传本地视频 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置页「功能设置」卡片新增「上传本地视频」入口，通过系统文件选择器多选本机视频并上传到已配置的 SMB 共享目录。

**Architecture:** 原生 `ACTION_OPEN_DOCUMENT`（SAF）返回选中视频的 uri/name/size → Dart 桥 `pickSmbFiles()` → 新增编排函数 `uploadLocalVideosToSmb()` 复用现有 `_SmbFolderPicker`、`_UploadProgressDialog` 与原生 `uploadToSmb`（借轻量 `DownloadTask` 传递 contentUri）。不新增依赖。

**Tech Stack:** Kotlin（MainActivity.kt）、Flutter MethodChannel/EventChannel、jcifs-ng（已有 SMB 上传核心，不动）。

## Global Constraints

- Flutter/Dart 仅用现有依赖，**不新增任何 package**。
- 原生放 `android/app/src/main/kotlin/io/github/alone4869/m3u8downloader/MainActivity.kt`，MethodChannel 名 `m3u8_downloader/methods`。
- 全部 UI 文案为简体中文（与现有 SMB 上传文案一致）。
- 遵循现有代码风格：私有类不跨文件导出、`ScaffoldMessenger` snackbar 提示、`runIo`/`onActivityResult` 模式。
- minSdk = 29。

---

### Task 1: 原生 `pickSmbFiles` 方法（SAF 视频选择器）

**Files:**
- Modify: `android/app/src/main/kotlin/io/github/alone4869/m3u8downloader/MainActivity.kt`
- 无 Android 单测设施（沿用仓库现状），验证方式为 Kotlin 编译通过。

**Interfaces:**
- Produces: MethodChannel `'pickSmbFiles'`，无入参；返回 `List<Map>`，每项 `{"uri": String, "name": String, "size": Long}`；用户取消返回 `emptyList`；已有未完成选择时 error（code `picker_busy`）。

- [ ] **Step 1: 添加 import 与字段**

在 `MainActivity.kt` 顶部 import 区（`import android.net.Uri` 之后）新增：

```kotlin
import android.provider.OpenableColumns
```

在类字段区（`private var pendingMediaPermissionResult: MethodChannel.Result? = null` 之后）新增：

```kotlin
private var pendingPickerResult: MethodChannel.Result? = null
```

- [ ] **Step 2: 添加 MethodChannel 分支**

在 `"listSmbFolders" -> { ... }` 分支之后、`"uploadToSmb" -> { ... }` 之前插入：

```kotlin
                "pickSmbFiles" -> {
                    if (pendingPickerResult != null) {
                        result.error("picker_busy", "正在等待上次的文件选择", null)
                        return@setMethodCallHandler
                    }
                    pendingPickerResult = result
                    startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "video/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        },
                        PICK_FILES_REQUEST,
                    )
                }
```

- [ ] **Step 3: 添加 onActivityResult 与元数据查询方法**

在 `onRequestPermissionsResult(...)` 方法之后插入：

```kotlin
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES_REQUEST) return
        val pending = pendingPickerResult ?: return
        pendingPickerResult = null
        if (resultCode != RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any>>())
            return
        }
        val uris = buildList {
            data.clipData?.let { clip ->
                repeat(clip.itemCount) { index -> add(clip.getItemAt(index).uri) }
            } ?: data.data?.let { add(it) }
        }
        runIo(pending) {
            uris.map { uri ->
                runCatching {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }
                mapOf(
                    "uri" to uri.toString(),
                    "name" to queryDisplayName(uri),
                    "size" to queryFileSize(uri),
                )
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String {
        val name = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index)
            } else {
                null
            }
        }?.trim()
        if (!name.isNullOrBlank()) return name
        return uri.lastPathSegment?.substringAfterLast('/').orEmpty().ifBlank { "video.mp4" }
    }

    private fun queryFileSize(uri: Uri): Long {
        contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            if (descriptor.statSize > 0L) return descriptor.statSize
        }
        return 0L
    }
```

- [ ] **Step 4: 添加请求码常量**

在 `companion object` 内（`MEDIA_PERMISSION_REQUEST = 1002` 之后）新增：

```kotlin
        private const val PICK_FILES_REQUEST = 1003
```

- [ ] **Step 5: 验证 Kotlin 编译**

Run: `cd android && ./gradlew :app:compileDebugKotlin -q`
Expected: BUILD SUCCESSFUL（零报错；若出现 deprecated 警告可忽略，项目已用旧式 `requestPermissions` 模式）。

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/io/github/alone4869/m3u8downloader/MainActivity.kt
git commit -m "feat: add SAF video picker for SMB upload"
```

---

### Task 2: Dart 桥 `SmbPickedFile` + `pickSmbFiles()`

**Files:**
- Modify: `lib/src/download_bridge.dart`
- Test: `test/download_task_test.dart`

**Interfaces:**
- Consumes: Task 1 原生 `pickSmbFiles` 通道。
- Produces: `class SmbPickedFile { final String uri; final String name; final int size; }`，含 `fromMap(Map<Object?, Object?>)`；`DownloadBridge.pickSmbFiles() → Future<List<SmbPickedFile>>`。

- [ ] **Step 1: 写失败测试**

向 `test/download_task_test.dart` 末尾（`main` 内最后一个 `});` 之前）追加：

```dart
  test('parses a picked local video entry', () {
    final file = SmbPickedFile.fromMap({
      'uri': 'content://media/external/video/42',
      'name': 'clip.mp4',
      'size': 1048576,
    });

    expect(file.uri, 'content://media/external/video/42');
    expect(file.name, 'clip.mp4');
    expect(file.size, 1048576);
  });

  test('requests local videos from the native picker', () async {
    const channel = MethodChannel('m3u8_downloader/methods');
    MethodCall? capturedCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      capturedCall = call;
      return [
        {
          'uri': 'content://media/external/video/42',
          'name': 'clip.mp4',
          'size': 1048576,
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final files = await DownloadBridge.instance.pickSmbFiles();

    expect(capturedCall?.method, 'pickSmbFiles');
    expect(files, hasLength(1));
    expect(files.first.name, 'clip.mp4');
    expect(files.first.size, 1048576);
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/download_task_test.dart`
Expected: 编译错误，提示 `SmbPickedFile` 未定义。

- [ ] **Step 3: 实现模型与方法**

在 `lib/src/download_bridge.dart` 中、`class SmbUploadProgress` 之后插入：

```dart
class SmbPickedFile {
  const SmbPickedFile({
    required this.uri,
    required this.name,
    required this.size,
  });

  factory SmbPickedFile.fromMap(Map<Object?, Object?> map) => SmbPickedFile(
    uri: map['uri'] as String? ?? '',
    name: map['name'] as String? ?? 'video.mp4',
    size: (map['size'] as num?)?.toInt() ?? 0,
  );

  final String uri;
  final String name;
  final int size;
}
```

在 `listSmbFolders(...)` 之后插入方法：

```dart
  Future<List<SmbPickedFile>> pickSmbFiles() async {
    final raw =
        await _methods.invokeListMethod<Object?>('pickSmbFiles') ?? const [];
    return raw
        .map(
          (item) =>
              SmbPickedFile.fromMap(Map<Object?, Object?>.from(item! as Map)),
        )
        .toList();
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/download_task_test.dart`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add lib/src/download_bridge.dart test/download_task_test.dart
git commit -m "feat: bridge pick local videos for SMB upload"
```

---

### Task 3: `uploadLocalVideosToSmb()` 编排（重构复用共享逻辑）

**Files:**
- Modify: `lib/src/smb_upload.dart`

**Interfaces:**
- Consumes: Task 1 的 `SmbPickedFile`、Task 2 的 `DownloadBridge.pickSmbFiles()`；已有 `_SmbFolderPicker`、`_UploadProgressDialog`、`SmbSettingsPage`。
- Produces: 顶层函数 `Future<void> uploadLocalVideosToSmb(BuildContext context)`（Task 4 消费）。重构后 `uploadTasksToSmb` 行为不变。

- [ ] **Step 1: 提取共享 SMB 配置检查**

将 `uploadTasksToSmb` 中「加载配置 + 未配置弹窗引导」部分（原 45–72 行区域 `var config = await SmbSettingsStore.instance.load(); ... }`）替换为对导出函数 `_ensureConfiguredSmb` 的调用。删除原内联段，并在文件顶部 import 区之后新增：

```dart
Future<SmbConfig?> _ensureConfiguredSmb(BuildContext context) async {
  var config = await SmbSettingsStore.instance.load();
  if (!context.mounted) return null;
  if (!config.isConfigured) {
    final configure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尚未配置 SMB'),
        content: const Text('请先填写 SMB 服务器和共享信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (configure != true || !context.mounted) return null;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const SmbSettingsPage()),
    );
    config = await SmbSettingsStore.instance.load();
    if (!config.isConfigured || !context.mounted) return null;
  }
  return config;
}
```

- [ ] **Step 2: `uploadTasksToSmb` 改为使用共享函数**

将 `uploadTasksToSmb` 中（`ensureLocalMediaAccess` 检查之后的）以下代码替换：

替换前：
```dart
  var config = await SmbSettingsStore.instance.load();
  if (!context.mounted) return;
  if (!config.isConfigured) {
    final configure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尚未配置 SMB'),
        content: const Text('请先填写 SMB 服务器和共享信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (configure != true || !context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const SmbSettingsPage()),
    );
    config = await SmbSettingsStore.instance.load();
    if (!config.isConfigured || !context.mounted) return;
  }
```

替换后：
```dart
  final config = await _ensureConfiguredSmb(context);
  if (config == null || !context.mounted) return;
```

- [ ] **Step 3: 提取共享上传执行 `_uploadTasksWithProgress`**

新增私有函数（放在 `uploadTasksToSmb` 之后），并将 `uploadTasksToSmb` 中「选文件夹到 finally 收尾」部分（原 74–114 行区域）整体替换为对其调用：

```dart
Future<void> _uploadTasksWithProgress(
  BuildContext context, {
  required SmbConfig config,
  required List<DownloadTask> tasks,
}) async {
  final folder = await showDialog<String>(
    context: context,
    builder: (context) => _SmbFolderPicker(config: config),
  );
  if (folder == null || !context.mounted) return;

  final uploadProgress = ValueNotifier<SmbUploadProgress?>(null);
  final progressSubscription = DownloadBridge.instance.smbUploadProgress.listen(
    (progress) => uploadProgress.value = progress,
  );
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UploadProgressDialog(
        progress: uploadProgress,
        fileCount: tasks.length,
      ),
    ),
  );
  try {
    await DownloadBridge.instance.uploadToSmb(config.toMap(), folder, tasks);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已上传 ${tasks.length} 个文件')));
  } catch (error) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('上传失败：$error')));
  } finally {
    await progressSubscription.cancel();
    uploadProgress.dispose();
  }
}
```

`uploadTasksToSmb` 此时末尾为：

```dart
  final config = await _ensureConfiguredSmb(context);
  if (config == null || !context.mounted) return;
  await _uploadTasksWithProgress(context, config: config, tasks: completed);
}
```

- [ ] **Step 4: 新增 `uploadLocalVideosToSmb`**

在 `uploadTasksToSmb` 定义的 `}` 之后、`_UploadProgressDialog` 类之前插入：

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

  final config = await _ensureConfiguredSmb(context);
  if (config == null || !context.mounted) return;

  final tasks = [
    for (final file in picked)
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

说明：`DownloadTask.id` 留空，原生 `uploadToSmb` 的 `onFileUploaded` 回调里 `ids.getOrNull(index)?.let { TaskStore.markUploaded(...) }` 对空 id 为 no-op，不会误标任何已下载任务。

- [ ] **Step 5: 验证静态分析**

Run: `flutter analyze`
Expected: No issues found（`smb_upload.dart`、`settings_view.dart` 引用的一致性由 analyzer 校验）。

- [ ] **Step 6: Commit**

```bash
git add lib/src/smb_upload.dart
git commit -m "feat: upload local videos to SMB from settings"
```

---

### Task 4: 设置页入口 + widget 测试

**Files:**
- Modify: `lib/src/settings_view.dart`
- Test: `test/settings_view_test.dart`（新建）

**Interfaces:**
- Consumes: Task 3 的顶层函数 `uploadLocalVideosToSmb(BuildContext)`；已有 `SettingsView` 的 `_SettingsIcon`、`_SettingsCard`。
- Produces: 设置页「功能设置」卡片新增「上传本地视频」ListTile（`onTap` 调 `uploadLocalVideosToSmb`）。

- [ ] **Step 1: 写失败 widget 测试**

新建 `test/settings_view_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8downloader/src/settings_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings shows the upload local video entry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(home: SettingsView()),
    );
    await tester.pump();

    expect(find.text('上传本地视频'), findsOneWidget);
    expect(find.text('选择本机视频并上传到 SMB'), findsOneWidget);
    expect(find.byIcon(Icons.video_library_outlined), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/settings_view_test.dart`
Expected: FAIL —— `find.text('上传本地视频')` 找不到。

- [ ] **Step 3: 添加 import**

在 `lib/src/settings_view.dart` import 区（`import 'smb_settings.dart';` 之后）新增：

```dart
import 'smb_upload.dart';
```

- [ ] **Step 4: 添加设置页 ListTile**

在 `SettingsView.build` 的功能设置 `_SettingsCard` 内，`SMB 上传` 的 ListTile 结束之后、卡片 children `],` 之前插入：

```dart
                const Divider(indent: 64),
                const ListTile(
                  leading: _SettingsIcon(Icons.video_library_outlined),
                  title: Text('上传本地视频'),
                  subtitle: Text('选择本机视频并上传到 SMB'),
                  trailing: Icon(Icons.chevron_right_rounded),
                ),
```

注意：入口为纯展示项。点击行为由父级 `HomeScreen` 暂不接线；如需点击触发，可将该 ListTile 改为非 const 并加 `onTap: () => uploadLocalVideosToSmb(context)`——本计划在 Step 5 中按此实现，保持测试同时验证入口存在。

- [ ] **Step 5: 接线 onTap**

将 Step 4 的 `const ListTile` 改为（去掉顶层 `const`，仅保留内部 const 子项）：

```dart
                const Divider(indent: 64),
                ListTile(
                  leading: const _SettingsIcon(Icons.video_library_outlined),
                  title: const Text('上传本地视频'),
                  subtitle: const Text('选择本机视频并上传到 SMB'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => uploadLocalVideosToSmb(context),
                ),
```

- [ ] **Step 6: 运行测试确认通过 + 全量回归**

Run: `flutter test test/settings_view_test.dart`
Expected: PASS（入口文案与图标均在）。

Run: `flutter test`
Expected: 全量 PASS（修改未破坏既有 20 个测试文件）。

Run: `flutter analyze`
Expected: No issues found。

- [ ] **Step 7: Commit**

```bash
git add lib/src/settings_view.dart test/settings_view_test.dart
git commit -m "feat: add upload local videos entry to settings"
```

---

## Self-Review 记录

- **Spec 覆盖**：原生 `pickSmbFiles`（Task 1）、桥模型与方法（Task 2）、上传编排（Task 3）、设置页入口（Task 4）、测试（Task 2 单测 + Task 4 widget 测）全部落地。
- **占位符扫描**：所有改动均给出完整代码，无 TBD/TODO。
- **类型一致性**：`SmbPickedFile` 字段 `uri/name/size`、`DownloadBridge.pickSmbFiles()`、`_ensureConfiguredSmb`、`_uploadTasksWithProgress` 签名在 Task 2/3/4 中引用一致。
# 分享视频上传到 SMB 功能设计文档

日期：2026-08-16
状态：已获用户确认

## 背景与目标

在上一版「SMB 上传本地视频」（设置页 SAF 多选）基础上，新增**系统分享入口**：用户在系统文件管理器/相册中多选视频，通过系统「分享」面板选择本 app，即可把视频批量上传到 SMB。

目标：
- 本 app 出现在系统分享面板（视频分享目标）
- 收到分享后展示确认页：列文件、可移除个别项、点「上传」再选 SMB 目录上传
- 复用现有的 SMB 配置检查、目录选择、进度对话框与多连接上传管道
- 不引入任何新依赖

## 现有架构参照

- SMB 上传后端：`SmbClient.kt`（jcifs-ng，SMB 2/3 多连接并行上传，进度事件上报）
- 原生通道：`MainActivity.kt` 的 `m3u8_downloader/methods` MethodChannel；上传进度走 `m3u8_downloader/upload_events` EventChannel
- Flutter 桥：`DownloadBridge.instance`（`download_bridge.dart`），已有 `SmbPickedFile{uri,name,size}` 模型与 `pickSmbFiles()`
- 上传编排：`smb_upload.dart` 的 `uploadLocalVideosToSmb()`——`_ensureConfiguredSmb` → `_SmbFolderPicker` → `_UploadProgressDialog` → `uploadToSmb`
- 入口容器：`app.dart` 的 `HomeScreen`（首页）

## 技术选型

- **通过系统分享 Intent 接收**：`MainActivity` 声明 `ACTION_SEND_MULTIPLE` / `ACTION_SEND` + `video/*` 的 intent-filter，出现在视频分享面板。单个视频走 `SEND`，多个走 `SEND_MULTIPLE`，两者都处理。
- 分享 Intent 携带的 content URI 是一次性临时读授权，仅在本 app 进程存活期间可读。因为上传紧随分享之后立刻发生，**不做** `takePersistableUriPermission`（对分享来源 URI 调用会抛 SecurityException，属无效操作）。
- 原生侧把分享 URI 缓存在内存中，Flutter 用新的 MethodChannel 方法一次性「消费」——既兼容冷启动（`onCreate`）又兼容热启动（`onNewIntent`，`singleTop` 复用实例）。
- 确认页为全屏 Flutter 页面（非对话框），原生只负责收 URI 与元数据，列表展示/移除/上传全部在 Flutter 侧。

## 架构与模块

### 1. `main/.../AndroidManifest.xml` — MainActivity 增加分享 intent-filter

在 `MainActivity` 的 `<intent-filter>` 之外再追加一个分享专用的 intent-filter（保留现有 MAIN/LAUNCHER filter）：

```xml
<intent-filter>
    <action android:name="android.intent.action.SEND" />
    <action android:name="android.intent.action.SEND_MULTIPLE" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:mimeType="video/*" />
</intent-filter>
```

> 说明：`MainActivity` 已 `exported="true"` 且 `singleTop`，无需改 activity 属性。

### 2. `main/.../MainActivity.kt` — 收分享 + 消费方法

- 新增字段 `pendingSharedFiles: List<Map<String, Any>>? = null`（内存缓存，Activity 销毁即失效，可接受）。
- `onCreate` 与 `onNewIntent`（均先 `super` 调用）：调 `SharedIntentHandling.handleShareIntent(intent, dest)`——仅当 `intent?.action` 为 `ACTION_SEND` 或 `ACTION_SEND_MULTIPLE` 时解析：
  - 收集 URI：`intent.clipData`（每项 `clip.getItemAt(i).uri`）；clipData 为 null 时回退 `intent` 的 `Parcelable EXTRA_STREAM`（单条也走它），以及 `intent.data`。
  - 复用 `queryDisplayName` / `queryFileSize`（`runIo` 线程池之外直接同步查询，或新建 helper）生成 `{uri,name,size}` 列表存入 `pendingSharedFiles`。注意：**不**调用 `takePersistableUriPermission`。
  - 解析失败/异常时静默放弃（置空即可），不让 app 崩溃。
- MethodChannel 新增分支：
  - `"consumeSharedVideos"`：取 `pendingSharedFiles` 并置空，返回列表；null 返回 `emptyList<Map<String, Any>>()`。
- `onDestroy` 置空缓存（可选，避免泄漏）。

### 3. `lib/src/download_bridge.dart` — 新增消费方法

- `Future<List<SmbPickedFile>> consumeSharedVideos() async`：`invokeListMethod<Object?>('consumeSharedVideos')`，逐项 `SmbPickedFile.fromMap`（与 `pickSmbFiles` 相同的解析）。MethodChannel 调用失败抛异常，由调用方处理。

### 4. `lib/src/share_upload_view.dart` — 新确认页（新文件）

- `class ShareUploadView extends StatefulWidget`（需要移除逻辑维护局部状态列表），构造参数接收 `List<SmbPickedFile> files`；State 持有 `late List<SmbPickedFile> _files = widget.files`。
- 结构：
  - `AppBar` 标题 `分享到 SMB`（默认返回按钮）。
  - 主体 `ListView.builder`：每项复用 `AppSurface`（玻璃风格卡片）元素；左侧缩略图（复用 app.dart 的 `_VideoThumbnail` 机制——通过临时 `DownloadTask(id:'', contentUri, fileName, fileSize)` 走原生 `getVideoThumbnail`，取不到时显示 `Icons.video_file` 占位）；中部文件名 + 格式化大小；右侧移除按钮（`Icons.close`），点击把该文件从 `_files` 中去掉（`setState`）。
- 底部固定 `FilledButton.icon(Icons.cloud_upload, '上传到 SMB')`：
  - `_files` 为空时禁用。
  - 点击：保持本页不 pop，直接 `uploadPickedVideosToSmb(context, _files)`——进度对话框覆盖在本页之上；上传完成后该函数负责 pop 掉进度对话框并在失败时留在本页，成功时仍留在确认页（用户可手动返回），避免 `context` 失效竞态。

### 5. `lib/src/smb_upload.dart` — 提取共用上传函数

- 新增公开函数 `Future<void> uploadPickedVideosToSmb(BuildContext context, List<SmbPickedFile> files)`：
  1. 空列表直接返回。
  2. `_ensureConfiguredSmb(context)`（未配置弹「去设置」对话框，复用现有私有实现）→ null 中止。
  3. `_SmbFolderPicker` 选目录。
  4. 构造临时 `DownloadTask` 列表 → `_uploadTasksWithProgress`（进度对话框，全部复用）。
  5. `_uploadTasksWithProgress` 成功后已弹「已上传 N 个文件」SnackBar；失败「上传失败：$error」。本函数不 pop 调用方页面（确认页），仅 `_uploadTasksWithProgress` 内部 pop 掉进度对话框。
- `uploadLocalVideosToSmb`（设置页入口）重构为：`pickSmbFiles()` 成功后调用 `uploadPickedVideosToSmb(context, picked)`，消除重复编排逻辑。

### 6. `lib/src/app.dart` — 冷/热启动入口触发

在 `_HomeScreenState.initState` 做一次异步消费（需 `mounted` 检查）：

- `final shared = await DownloadBridge.instance.consumeSharedVideos();`
- 非空时：切换到首页（若当前不在首页，先切到首页 tab），再 `Navigator.push(ShareUploadView(files: shared))`。
- 为空或抛错：静默返回（正常启动不受影响）；抛错可忽略或 snackbar「接收分享失败」。

> 说明：分享进入时 app 的 Flutter 首帧先渲染，`initState` 的异步消费完成后 push 确认页，体验自然，无需额外路由配置。

## 数据流

```
系统相册/文件管理器 多选视频 → 分享面板选「M3U8 视频下载器」
  → [MainActivity onCreate/onNewIntent] 解析 clipData → pendingSharedFiles 缓存
  → HomeScreen.initState → consumeSharedVideos() 取走并清空缓存
  → ShareUploadView 确认页（列文件 / 移除项 / 上传按钮）
  → [未配置 SMB] 弹「去设置」对话框
  → _SmbFolderPicker 选远端目录
  → _UploadProgressDialog + uploadToSmb
  → [upload_events] 实时进度 → 完成/失败 SnackBar
```

## 错误处理

- 分享 Intent 无 URI / 解析失败：原生返回空列表，Flutter 静默不弹确认页。
- SMB 未配置：弹现有「尚未配置 SMB」对话框，引导进 `SmbSettingsPage`，配好后继续。
- 上传失败：沿用 `_uploadTasksWithProgress` 现有「上传失败：$error」逻辑。
- 分享 URI 授权过期（用户长时间不使用）：`uploadToSmb` 读文件失败会抛错并展示失败 SnackBar；属预期边界（分享→上传为短链路，实际很少触发）。
- `consumeSharedVideos` MethodChannel 抛错：catch 后静默返回，不阻断启动。

## 测试计划

- `download_bridge_test`：`consumeSharedVideos` 的 MethodChannel mock（非空/空列表/错误）。
- `share_upload_view` widget 测试（新测试文件）：
  - 传入 2 个文件渲染列表（名称/大小）；
  - 点移除后该项消失且上传按钮在空列表时禁用。
- `smb_upload_test`：`uploadPickedVideosToSmb` 空列表直接返回（不触发原生调用）。
- 手动验证清单：真机从相册分享 1 个与多个视频，分别验证冷启动与热启动路径、移除项、未配置 SMB 弹窗引导、上传进度与完成提示。

## 不做（YAGNI）

- 不做 `takePersistableUriPermission`（分享来源不可持久化）。
- 不做分享失败重试队列、上传历史记录。
- 不新增任何第三方依赖。
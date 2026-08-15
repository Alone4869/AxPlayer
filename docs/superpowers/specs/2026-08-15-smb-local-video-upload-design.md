# SMB 上传本地视频功能设计文档

日期：2026-08-15
状态：已获用户确认

## 背景与目标

在设置页的「SMB 上传」区域新增**上传本地视频**能力：从本机（相册/任意文件夹）选择视频文件并上传到已配置的 SMB 共享目录。当前 SMB 上传仅支持把 App 自己下载完成的任务传到 NAS，无法选择设备上的其他视频。

目标：
- 设置页新增「上传本地视频」入口
- 通过系统文件选择器多选本机视频（无需媒体权限）
- 复用现有 SMB 多连接上传核心与进度 UI
- 选择、检查配置、选目标文件夹、上传的完整链路

## 现有架构参照

- SMB 上传后端：`SmbClient.kt`（jcifs-ng，SMB 2/3 多连接并行上传，进度事件上报）
- 原生通道：`MainActivity.kt` 的 `m3u8_downloader/methods` MethodChannel，已有 `testSmb` / `listSmbFolders` / `uploadToSmb`；上传进度走 `m3u8_downloader/upload_events` EventChannel
- Flutter 桥：`DownloadBridge.instance`（`download_bridge.dart`）
- 上传编排：`smb_upload.dart` 的 `uploadTasksToSmb()`——检查媒体权限 → 检查 SMB 配置 → `_SmbFolderPicker` 选文件夹 → `_UploadProgressDialog` 显示进度 → `uploadToSmb`
- 设置页：`settings_view.dart` 的 `SettingsView`，功能设置卡片里有「SMB 上传」ListTile 进入 `SmbSettingsPage`

## 技术选型

- **不引入任何新依赖**。
- 用 Android 系统文件选择器（Storage Access Framework，`ACTION_OPEN_DOCUMENT`），`video/*` + `EXTRA_ALLOW_MULTIPLE`，无需读写媒体权限。
- 选中后 `takePersistableUriPermission` 持久化读授权，保证上传期间（含稍后继续）可读取。
- 上传阶段直接复用现有原生 `uploadToSmb`——其内部用 contentUri 读取文件，对本地任意视频同样适用；给 `LocalDownloads.resolve` 传入的 contentUri 可读即可命中。

## 架构与模块

### 1. `main/.../MainActivity.kt` — 新增原生方法 `pickSmbFiles`

- 新增 `pendingPickerResult: MethodChannel.Result?` 字段 + `PICK_FILES_REQUEST` 常量。
- MethodChannel 增加分支：
  - `"pickSmbFiles"`：若已有 pending，直接 error（避免并发）；否则保存 result，`startActivityForResult` 启动 `ACTION_OPEN_DOCUMENT`（`type="video/*"`、`EXTRA_ALLOW_MULTIPLE=true`、`CATEGORY_OPENABLE`）。
  - `onActivityResult`（新增 override）处理 `PICK_FILES_REQUEST`：取消则 `result.success(emptyList)`；否则收集所有选中 URI，对每个 `takePersistableUriPermission(uri, FLAG_GRANT_READ_URI_PERMISSION)`，并查询 display name 与 size，返回 `List<Map<String, Any>>`（`uri` / `name` / `size`）。
  - 用 `runIo` 包裹元数据查询，避免阻塞 UI 线程。

### 2. `lib/src/download_bridge.dart` — 新增模型与方法

- `class SmbPickedFile { uri, name, size }` + `fromMap`
- `Future<List<SmbPickedFile>> pickSmbFiles()` —— invoke `pickSmbFiles`
- 复用现有 `uploadToSmb(config, path, tasks)` 签名不变：上传编排侧为每个选中文件构造轻量 `DownloadTask`（`id` 留空、`status=completed`、`contentUri=uri`、`fileName=name`、`fileSize=size`）。原生 `uploadToSmb` 只取 fileNames/contentUris/fileSizes，`onFileUploaded` 用 id 标记已上传——空 id 时 `ids.getOrNull(index)` 为 null，自动 no-op，无需改原生逻辑。

### 3. `lib/src/smb_upload.dart` — 新增 `uploadLocalVideosToSmb()`

流程（与 `uploadTasksToSmb` 平行）：
1. `final files = await DownloadBridge.instance.pickSmbFiles();` 空则 snackbar「未选择任何视频」并返回。
2. 检查 SMB 配置：未配置时弹「尚未配置 SMB」对话框 → 引导进 `SmbSettingsPage`（复用现有逻辑，可提取共用帮助函数）。
3. `_SmbFolderPicker` 选目标文件夹（复用）。
4. `_UploadProgressDialog` 显示进度（复用），`fileCount = files.length`。
5. 调用 `uploadToSmb`（contentUris 为选中的 uri）。成功 snackbar「已上传 N 个文件」；失败「上传失败：$error」；finally 取消订阅、释放 notifier。

> 说明：`_SmbFolderPicker`、`_UploadProgressDialog`、SMB 配置检查对话框在 `smb_upload.dart` 中为私有类，直接在同一文件内复用，不跨文件导出。

### 4. `lib/src/settings_view.dart` — 设置页新增入口

- 在「功能设置」卡片「SMB 上传」ListTile 下方新增 ListTile：
  - leading：`Icons.video_library_outlined`
  - title：`上传本地视频`
  - subtitle：`选择本机视频并上传到 SMB`
  - onTap：`uploadLocalVideosToSmb(context)`
- 需要 `import 'smb_upload.dart';`

## 数据流

```
设置页点「上传本地视频」
  → uploadLocalVideosToSmb(context)
  → pickSmbFiles()  [原生 SAF 多选，无权限请求]
  → → [未配置] 弹窗引导 SmbSettingsPage
  → _SmbFolderPicker 选远端目录  [listSmbFolders]
  → _UploadProgressDialog + uploadToSmb
  → [upload_events] 实时进度（速度/字节/文件/协议）
  → 完成 snackbar / 失败 snackbar
```

## 错误处理

- 取消选择：返回空列表，静默返回。
- 未配置 SMB：弹窗引导，成功后继续。
- 某个文件无法读取：原生上传抛错，外层展示「上传失败：$error」，`SmbClient` 已负责清理未完成的远端残文件。
- 上传期间重复点入口：pending result 保护会返回 error，前端忽略（每个入口调用本身已非阻塞多选）。

## 测试计划

- `download_bridge_test`（或并入现有测试文件）：`SmbPickedFile.fromMap` 解析。
- 设置页 widget 测试：新增「上传本地视频」入口渲染；`uploadLocalVideosToSmb` 因强依赖原生 MethodChannel 与对话框，widget 测试仅验证入口存在与标题文案，不 mock 原生。
- 不新增 SMB 原生单元测试（沿用仓库现状——Android 侧无测试）。
package io.github.alone4869.axplayer

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import android.util.Size
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var eventSink: EventChannel.EventSink? = null
    private var uploadEventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val thumbnailExecutor = Executors.newFixedThreadPool(THUMBNAIL_THREADS)
    private var pendingMediaPermissionResult: MethodChannel.Result? = null
    private var pendingPickerResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingSharedFiles: List<Map<String, Any>>? = null

    private val taskReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val json = intent?.getStringExtra(DownloadService.EXTRA_TASK) ?: return
            eventSink?.success(TaskStore.jsonToMap(json))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consumeShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeShareIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "startDownload" -> {
                    val url = call.argument<String>("url")?.trim().orEmpty()
                    val fileName = call.argument<String>("fileName")?.trim().orEmpty()
                    val cookie = call.argument<String>("cookie").orEmpty()
                    val sourceUrl = call.argument<String>("sourceUrl")?.trim().orEmpty()
                    val taskId = call.argument<String>("taskId")?.trim().orEmpty()
                    if (url.isBlank() || fileName.isBlank()) {
                        result.error("invalid_arguments", "下载链接和文件名不能为空", null)
                        return@setMethodCallHandler
                    }
                    requestNotificationPermissionIfNeeded()
                    val intent = Intent(this, DownloadService::class.java).apply {
                        action = DownloadService.ACTION_START
                        putExtra(DownloadService.EXTRA_URL, url)
                        putExtra(DownloadService.EXTRA_FILE_NAME, fileName)
                        putExtra(DownloadService.EXTRA_COOKIE, cookie)
                        putExtra(DownloadService.EXTRA_SOURCE_URL, sourceUrl)
                        putExtra(DownloadService.EXTRA_ID, taskId)
                    }
                    ContextCompat.startForegroundService(this, intent)
                    result.success(null)
                }

                "cancelDownload" -> {
                    val id = call.argument<String>("id").orEmpty()
                    startService(Intent(this, DownloadService::class.java).apply {
                        action = DownloadService.ACTION_CANCEL
                        putExtra(DownloadService.EXTRA_ID, id)
                    })
                    result.success(null)
                }

                // 传入本进程活跃的任务 id，让存储层把已经没有线程执行的残留任务
                // 对账成失败状态。顺带放到 IO 线程：这里会查询 MediaStore 补全
                // 文件信息，留在主线程会拖住首帧。
                "getTasks" -> runIo(result) {
                    TaskStore.getTasks(this, DownloadService.runningIds)
                }
                "getAppInfo" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        info.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        info.versionCode.toLong()
                    }
                    result.success(
                        mapOf(
                            "versionName" to info.versionName.orEmpty(),
                            "versionCode" to versionCode,
                            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                        ),
                    )
                }
                "openUrl" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val uri = Uri.parse(url)
                    if (uri.scheme !in setOf("http", "https")) {
                        result.error("invalid_url", "仅支持 HTTP 或 HTTPS 地址", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("open_failed", error.message ?: "无法打开下载地址", null)
                    }
                }
                "ensureLocalMediaAccess" -> {
                    val fileNames = call.argument<List<String>>("fileNames").orEmpty()
                    val contentUris = call.argument<List<String>>("contentUris").orEmpty()
                    val fileSizes = call.argument<List<Number>>("fileSizes").orEmpty().map { it.toLong() }
                    runIo(result) {
                        val allReadable = fileNames.indices.all { index ->
                            LocalDownloads.resolve(
                                this,
                                contentUris.getOrNull(index).orEmpty(),
                                fileNames[index],
                                fileSizes.getOrNull(index) ?: 0L,
                            ) != null
                        }
                        if (allReadable) {
                            true
                        } else {
                            runOnUiThread { requestMediaPermission(result) }
                            ASYNC_RESULT
                        }
                    }
                }
                "openVideo" -> {
                    val fileName = call.argument<String>("fileName").orEmpty()
                    val contentUri = call.argument<String>("contentUri").orEmpty()
                    val fileSize = (call.argument<Number>("fileSize"))?.toLong() ?: 0L
                    try {
                        openDownloadedVideo(fileName, contentUri, fileSize)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("open_failed", error.message ?: "无法打开视频", null)
                    }
                }
                "playVideo" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val playerPackage = call.argument<String>("package").orEmpty()
                    if (url.isBlank()) {
                        result.error("invalid_arguments", "播放地址不能为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            if (playerPackage == "is.xyz.mpv") {
                                setDataAndType(Uri.parse(url), "video/any")
                            } else {
                                setDataAndType(Uri.parse(url), "video/*")
                            }
                            if (playerPackage.isNotBlank()) setPackage(playerPackage)
                        }
                        if (intent.resolveActivity(packageManager) == null) {
                            result.error("no_player", "系统中没有可播放此视频的应用", null)
                            return@setMethodCallHandler
                        }
                        startActivity(intent)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("play_failed", error.message ?: "无法播放", null)
                    }
                }
                "playInApp" -> {
                    val url = call.argument<String>("url").orEmpty()
                    if (url.isBlank()) {
                        result.error("invalid_arguments", "播放地址不能为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(PlayerActivity.newIntent(this, url))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("play_failed", error.message ?: "无法播放", null)
                    }
                }
                "queryVideoPlayers" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val players = KNOWN_VIDEO_PLAYERS.mapNotNull { (pkg, label, mime) ->
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(Uri.parse(url), mime)
                            setPackage(pkg)
                        }
                        if (intent.resolveActivity(packageManager) != null) {
                            mapOf("package" to pkg, "label" to label)
                        } else {
                            null
                        }
                    }
                    result.success(players)
                }
                "getVideoThumbnail" -> {
                    val fileName = call.argument<String>("fileName").orEmpty()
                    val contentUri = call.argument<String>("contentUri").orEmpty()
                    val fileSize = (call.argument<Number>("fileSize"))?.toLong() ?: 0L
                    runIo(result) { createVideoThumbnail(fileName, contentUri, fileSize) }
                }
                "deleteTasks" -> {
                    val ids = call.argument<List<String>>("ids").orEmpty().toSet()
                    val fileNames = call.argument<List<String>>("fileNames").orEmpty()
                    val contentUris = call.argument<List<String>>("contentUris").orEmpty()
                    val fileSizes = call.argument<List<Number>>("fileSizes").orEmpty().map { it.toLong() }
                    val deleteFiles = call.argument<Boolean>("deleteFiles") == true
                    runIo(result) {
                        if (deleteFiles) {
                            fileNames.forEachIndexed { index, fileName ->
                                deleteDownloadedFile(
                                    fileName,
                                    contentUris.getOrNull(index).orEmpty(),
                                    fileSizes.getOrNull(index) ?: 0L,
                                )
                            }
                        }
                        TaskStore.delete(this, ids)
                        null
                    }
                }
                "testSmb" -> {
                    val config = SmbConfig.fromMap(call.argument<Map<*, *>>("config").orEmpty())
                    runIo(result) {
                        SmbClient(this, config).testConnection()
                        null
                    }
                }
                "listSmbFolders" -> {
                    val config = SmbConfig.fromMap(call.argument<Map<*, *>>("config").orEmpty())
                    val path = call.argument<String>("path").orEmpty()
                    runIo(result) { SmbClient(this, config).listFolders(path) }
                }
                "pickSmbFiles" -> {
                    if (pendingPickerResult != null) {
                        result.error("picker_busy", "正在等待上次的文件选择", null)
                        return@setMethodCallHandler
                    }
                    pendingPickerResult = result
                    try {
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "video/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            },
                            PICK_FILES_REQUEST,
                        )
                    } catch (error: Exception) {
                        pendingPickerResult = null
                        result.error("picker_launch_failed", error.message ?: "无法打开文件选择器", null)
                    }
                }
                "consumeSharedVideos" -> {
                    val files = pendingSharedFiles
                    pendingSharedFiles = null
                    result.success(files ?: emptyList<Map<String, Any>>())
                }
                "pickLocalFolder" -> {
                    if (pendingFolderResult != null) {
                        result.error("picker_busy", "正在等待上次的文件夹选择", null)
                        return@setMethodCallHandler
                    }
                    pendingFolderResult = result
                    try {
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                                )
                            },
                            PICK_FOLDER_REQUEST,
                        )
                    } catch (error: Exception) {
                        pendingFolderResult = null
                        result.error(
                            "picker_launch_failed",
                            error.message ?: "无法打开文件夹选择器",
                            null,
                        )
                    }
                }
                "listLocalVideos" -> {
                    val raw = call.argument<String>("treeUri").orEmpty()
                    if (raw.isBlank()) {
                        result.error("invalid_arguments", "文件夹地址不能为空", null)
                        return@setMethodCallHandler
                    }
                    val treeUri = Uri.parse(raw)
                    runIo(result) {
                        // 授权被系统回收时 query 只会返回空，界面会误报"没有视频"
                        if (!LocalFolder.hasPermission(this, treeUri)) {
                            throw IllegalStateException("文件夹授权已失效，请重新选择")
                        }
                        LocalFolder.listVideos(this, treeUri).map { entry ->
                            mapOf(
                                "uri" to entry.uri.toString(),
                                "name" to entry.name,
                                "size" to entry.size,
                                "mimeType" to entry.mimeType,
                                "lastModified" to entry.lastModified,
                                "relativePath" to entry.relativePath,
                            )
                        }
                    }
                }
                "getLocalVideoThumbnail" -> {
                    val raw = call.argument<String>("uri").orEmpty()
                    if (raw.isBlank()) {
                        result.error("invalid_arguments", "文件地址不能为空", null)
                        return@setMethodCallHandler
                    }
                    val uri = Uri.parse(raw)
                    val lastModified = (call.argument<Number>("lastModified"))?.toLong() ?: 0L
                    // 走独立线程池：一屏十几张缩略图，串行解码会让后面的卡片长时间空着
                    runIoParallel(result) {
                        LocalFolder.thumbnail(this, uri, lastModified)?.let { thumb ->
                            mapOf("bytes" to thumb.bytes, "durationMs" to thumb.durationMs)
                        }
                    }
                }
                "openLocalVideo" -> {
                    val uris = call.argument<List<String>>("uris").orEmpty()
                    val titles = call.argument<List<String>>("titles").orEmpty()
                    val index = (call.argument<Number>("index"))?.toInt() ?: 0
                    val single = call.argument<String>("uri").orEmpty()
                    if (uris.isEmpty() && single.isBlank()) {
                        result.error("invalid_arguments", "文件地址不能为空", null)
                        return@setMethodCallHandler
                    }
                    val intent = if (uris.isNotEmpty()) {
                        PlayerActivity.playlistIntent(this, uris, titles, index)
                    } else {
                        PlayerActivity.newIntent(
                            this,
                            single,
                            call.argument<String>("title").orEmpty(),
                        )
                    }
                    startActivity(intent)
                    result.success(null)
                }
                "forgetPlaybackProgress" -> {
                    val uris = call.argument<List<String>>("uris").orEmpty()
                    getSharedPreferences(PLAYBACK_PREFS, MODE_PRIVATE).edit().apply {
                        uris.forEach { remove(it) }
                        apply()
                    }
                    result.success(null)
                }
                "getPlaybackHistory" -> {
                    val prefs = getSharedPreferences(PLAYBACK_PREFS, MODE_PRIVATE)
                    val history = prefs.all.mapNotNull { (uri, value) ->
                        val raw = value as? String ?: return@mapNotNull null
                        val json = runCatching { org.json.JSONObject(raw) }.getOrNull()
                            ?: return@mapNotNull null
                        uri to mapOf(
                            "uri" to uri,
                            "position" to json.optLong("position", 0L),
                            "duration" to json.optLong("duration", 0L),
                            "updatedAt" to json.optLong("updatedAt", 0L),
                            "title" to json.optString("title", ""),
                        )
                    }.toMap()
                    result.success(history)
                }
                "uploadToSmb" -> {
                    val config = SmbConfig.fromMap(call.argument<Map<*, *>>("config").orEmpty())
                    val path = call.argument<String>("path").orEmpty()
                    val ids = call.argument<List<String>>("ids").orEmpty()
                    val fileNames = call.argument<List<String>>("fileNames").orEmpty()
                    val contentUris = call.argument<List<String>>("contentUris").orEmpty()
                    val fileSizes = call.argument<List<Number>>("fileSizes").orEmpty().map { it.toLong() }
                    runIo(result) {
                        SmbClient(this, config).upload(
                            path = path,
                            fileNames = fileNames,
                            contentUris = contentUris,
                            fileSizes = fileSizes,
                            onProgress = { progress ->
                                runOnUiThread { uploadEventSink?.success(progress) }
                            },
                            onFileUploaded = { index ->
                                ids.getOrNull(index)?.let { id ->
                                    TaskStore.markUploaded(this, setOf(id)).forEach(::broadcastTask)
                                }
                            },
                        )
                        null
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    registerTaskReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    unregisterTaskReceiver()
                }
            },
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, UPLOAD_EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    uploadEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    uploadEventSink = null
                }
            },
        )
    }

    private fun registerTaskReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(DownloadService.ACTION_TASK_UPDATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(taskReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(taskReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterTaskReceiver() {
        if (!receiverRegistered) return
        unregisterReceiver(taskReceiver)
        receiverRegistered = false
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun requestMediaPermission(result: MethodChannel.Result) {
        val permissions = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> arrayOf(
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        if (permissions.any { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            result.success(true)
            return
        }
        if (pendingMediaPermissionResult != null) {
            result.error("permission_pending", "正在等待视频访问授权", null)
            return
        }
        pendingMediaPermissionResult = result
        requestPermissions(permissions, MEDIA_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MEDIA_PERMISSION_REQUEST) {
            pendingMediaPermissionResult?.success(
                grantResults.any { it == PackageManager.PERMISSION_GRANTED },
            )
            pendingMediaPermissionResult = null
        }
    }

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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_FOLDER_REQUEST) {
            handleFolderPicked(resultCode, data)
            return
        }
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
                }.onFailure { Log.w("MainActivity", "cannot persist read grant for $uri", it) }
                mapOf(
                    "uri" to uri.toString(),
                    "name" to runCatching { queryDisplayName(uri) }.getOrElse { fallbackDisplayName(uri) },
                    "size" to runCatching { queryFileSize(uri) }.getOrDefault(0L),
                )
            }
        }
    }

    private fun handleFolderPicked(resultCode: Int, data: Intent?) {
        val pending = pendingFolderResult ?: return
        pendingFolderResult = null
        val treeUri = data?.data
        if (resultCode != RESULT_OK || treeUri == null) {
            pending.success(null)
            return
        }
        runIo(pending) {
            // 持久化授权，否则下次启动读不到这个文件夹
            runCatching {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }.onFailure {
                Log.w("MainActivity", "cannot persist tree grant for $treeUri", it)
            }
            mapOf(
                "uri" to treeUri.toString(),
                "name" to LocalFolder.folderName(this, treeUri),
            )
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
                if (index >= 0) cursor.getString(index) else null
            } else {
                null
            }
        }?.trim()
        if (!name.isNullOrBlank()) return name
        return fallbackDisplayName(uri)
    }

    private fun fallbackDisplayName(uri: Uri): String =
        uri.lastPathSegment?.substringAfterLast('/').orEmpty().ifBlank { "video.mp4" }

    private fun queryFileSize(uri: Uri): Long {
        contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            if (descriptor.statSize > 0L) return descriptor.statSize
        }
        return 0L
    }

    private fun openDownloadedVideo(fileName: String, contentUri: String, fileSize: Long) {
        val uri = LocalDownloads.resolve(this, contentUri, fileName, fileSize)
            ?: throw IllegalStateException("未找到或无法读取已下载的视频文件")

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, if (fileName.endsWith(".ts", true)) "video/mp2t" else "video/mp4")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (intent.resolveActivity(packageManager) == null) {
            throw IllegalStateException("系统中没有可播放此视频的应用")
        }
        startActivity(intent)
    }

    private fun createVideoThumbnail(
        fileName: String,
        contentUri: String,
        fileSize: Long,
    ): ByteArray? {
        val uri = LocalDownloads.resolve(this, contentUri, fileName, fileSize) ?: return null
        val bitmap = runCatching {
            contentResolver.loadThumbnail(uri, Size(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT), null)
        }.getOrNull() ?: runCatching {
            MediaMetadataRetriever().use { retriever ->
                retriever.setDataSource(this, uri)
                retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
        }.getOrNull() ?: return null

        return ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)
            output.toByteArray()
        }
    }

    private fun deleteDownloadedFile(fileName: String, contentUri: String, fileSize: Long) {
        LocalDownloads.resolve(this, contentUri, fileName, fileSize)?.let { uri ->
            contentResolver.delete(uri, null, null)
        }
    }

    private fun broadcastTask(task: org.json.JSONObject) {
        sendBroadcast(Intent(DownloadService.ACTION_TASK_UPDATE).apply {
            setPackage(packageName)
            putExtra(DownloadService.EXTRA_TASK, task.toString())
        })
    }

    private fun runIo(result: MethodChannel.Result, operation: () -> Any?) {
        ioExecutor.execute {
            try {
                val value = operation()
                if (value !== ASYNC_RESULT) runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("operation_failed", error.message ?: "操作失败", null)
                }
            }
        }
    }

    /** 缩略图专用：并发解码，避免一屏卡片排队等同一根线程。 */
    private fun runIoParallel(result: MethodChannel.Result, operation: () -> Any?) {
        thumbnailExecutor.execute {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("operation_failed", error.message ?: "操作失败", null)
                }
            }
        }
    }

    override fun onDestroy() {
        ioExecutor.shutdownNow()
        thumbnailExecutor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val METHODS = "axplayer/methods"
        private const val EVENTS = "axplayer/events"
        private const val UPLOAD_EVENTS = "axplayer/upload_events"
        private const val MEDIA_PERMISSION_REQUEST = 1002
        private const val PICK_FILES_REQUEST = 1003
        private const val PICK_FOLDER_REQUEST = 1004
        private const val PLAYBACK_PREFS = "playback_progress"
        private const val SHARE_SEND = Intent.ACTION_SEND
        private const val SHARE_SEND_MULTIPLE = Intent.ACTION_SEND_MULTIPLE
        private const val THUMBNAIL_WIDTH = 320
        private const val THUMBNAIL_HEIGHT = 180
        private const val THUMBNAIL_THREADS = 4
        private val ASYNC_RESULT = Any()
        private val KNOWN_VIDEO_PLAYERS = listOf(
            Triple("org.videolan.vlc", "VLC", "video/*"),
            Triple("is.xyz.mpv", "MPV", "video/any"),
            Triple("com.mxtech.videoplayer.ad", "MX Player", "video/*"),
        )
    }
}

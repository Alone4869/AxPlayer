package io.github.alone4869.axplayer

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import org.json.JSONObject

/**
 * 通过 SAF 树 URI 读取用户选中的本地文件夹。
 *
 * 只用 [DocumentsContract] 查询，不引入 documentfile 依赖：一次 query 就能拿到
 * 子项的 id、名称、大小与修改时间，比逐层构造 DocumentFile 便宜得多。
 */
data class LocalVideoEntry(
    val uri: Uri,
    val name: String,
    val size: Long,
    val mimeType: String,
    val lastModified: Long,
    val relativePath: String,
)

/**
 * 缩略图只回传磁盘路径，不回传字节。
 *
 * 走路径让 Flutter 把解码交给自己的图片缓存：同一张图在网格、继续观看、播放历史
 * 三处共用一份缓存，也省掉每个条目几十 KB 的通道拷贝——滑动时那是最直接的卡顿来源。
 */
data class LocalThumbnail(val path: String, val durationMs: Long)

object LocalFolder {
    private val PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )

    private val VIDEO_SUFFIXES = setOf(
        "mp4", "mkv", "webm", "mov", "avi", "ts", "m4v", "flv", "wmv", "mpg", "mpeg", "3gp",
    )

    private const val MAX_DEPTH = 6
    private const val MAX_ITEMS = 2000
    private const val THUMBNAIL_WIDTH = 480
    private const val THUMBNAIL_HEIGHT = 270
    private const val THUMBNAIL_QUALITY = 80
    private const val PREWARM_LIMIT = 16

    /** 同一个文件的缩略图并发请求只解码一次：预取和可见卡片经常同时要它。 */
    private val decodeLocks = ConcurrentHashMap<String, Any>()

    /** 预取用单线程低优先级线程池，只在用户还没滑到那里时补位。 */
    private val warmer = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "axplayer-thumbnails").apply { priority = Thread.MIN_PRIORITY }
    }

    fun hasPermission(context: Context, treeUri: Uri): Boolean = runCatching {
        context.contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission
        }
    }.getOrDefault(false)

    fun folderName(context: Context, treeUri: Uri): String {
        val documentUri = runCatching {
            DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
        }.getOrNull() ?: return treeUri.lastPathSegment.orEmpty()
        val queried = runCatching {
            context.contentResolver.query(
                documentUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
        return queried.orEmpty().ifBlank { treeUri.lastPathSegment.orEmpty() }
    }

    fun listVideos(context: Context, treeUri: Uri): List<LocalVideoEntry> {
        val rootId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()
            ?: return emptyList()
        val videos = mutableListOf<LocalVideoEntry>()
        val visited = mutableSetOf<String>()
        walk(context, treeUri, rootId, "", 0, videos, visited)
        return videos.sortedWith(
            compareBy<LocalVideoEntry> { it.relativePath.count { ch -> ch == '/' } }
                .thenBy { it.relativePath.lowercase() },
        )
    }

    /**
     * 列表刚出来就在后台把首屏缩略图先解好。
     *
     * 首屏十几张图如果等卡片建出来再逐张解码，用户看到的就是"一块一块地亮"；
     * 提前算好之后，滑到哪儿都是直接从磁盘缓存读。
     */
    fun prewarm(context: Context, videos: List<LocalVideoEntry>, limit: Int = PREWARM_LIMIT) {
        if (videos.isEmpty()) return
        val app = context.applicationContext
        val slice = videos.take(limit)
        runCatching {
            warmer.execute {
                for (entry in slice) {
                    runCatching { thumbnail(app, entry.uri, entry.lastModified) }
                }
            }
        }
    }

    /**
     * 生成缩略图，命中磁盘缓存时直接返回路径。
     *
     * 缓存放在 cacheDir：系统空间紧张时可以回收，重新生成即可，不需要用户清理。
     * 缓存键只取 uri，修改时间和时长记在同名 `.meta` 里——这样同一文件无论从网格
     * 还是从播放历史打开，都会命中同一份缓存，不会重复解码。
     */
    fun thumbnail(context: Context, uri: Uri, lastModified: Long = 0L): LocalThumbnail? {
        val dir = thumbnailDir(context)
        val key = digest(uri.toString())
        lookup(dir, key, lastModified).let { hit ->
            if (hit.found) return hit.thumbnail
        }
        val lock = decodeLocks.computeIfAbsent(key) { Any() }
        try {
            synchronized(lock) {
                lookup(dir, key, lastModified).let { hit ->
                    if (hit.found) return hit.thumbnail
                }
                return generate(context, dir, key, uri, lastModified)
            }
        } finally {
            decodeLocks.remove(key, lock)
        }
    }

    private class CacheLookup(val found: Boolean, val thumbnail: LocalThumbnail?)

    private fun lookup(dir: File, key: String, lastModified: Long): CacheLookup {
        val image = File(dir, "$key.jpg")
        val meta = File(dir, "$key.meta")
        val bad = File(dir, "$key.none")

        if (!image.exists()) {
            // 上次就取不到画面的文件别再试，否则每次滑回来都要卡一下
            if (bad.exists() && markerMatches(bad, lastModified)) return CacheLookup(true, null)
            return CacheLookup(false, null)
        }

        val stored = runCatching { JSONObject(meta.readText()) }.getOrNull()
        val storedModified = stored?.optLong("mtime", 0L) ?: 0L
        if (lastModified > 0L && storedModified > 0L && storedModified != lastModified) {
            // 文件被替换过，旧图已经不是它了
            image.delete()
            meta.delete()
            return CacheLookup(false, null)
        }
        val duration = stored?.optLong("duration", 0L) ?: 0L
        if (lastModified > 0L && storedModified == 0L) {
            // 从播放历史进来的请求不知道修改时间，顺手补上，之后才谈得上按 mtime 判失效
            runCatching {
                meta.writeText(
                    JSONObject().put("mtime", lastModified).put("duration", duration).toString(),
                )
            }
        }
        return CacheLookup(true, LocalThumbnail(image.path, duration))
    }

    private fun markerMatches(marker: File, lastModified: Long): Boolean {
        if (lastModified <= 0L) return true
        val stored = runCatching { marker.readText().trim().toLongOrNull() }.getOrNull() ?: return false
        if (stored == lastModified) return true
        marker.delete()
        return false
    }

    private fun generate(
        context: Context,
        dir: File,
        key: String,
        uri: Uri,
        lastModified: Long,
    ): LocalThumbnail? {
        var duration = 0L
        val bitmap = runCatching {
            MediaMetadataRetriever().use { retriever ->
                retriever.setDataSource(context, uri)
                duration = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                // 取 10% 处的关键帧：片头常是黑场或台标，固定 1 秒未必有画面
                val atMicros = (duration * 100L).coerceAtLeast(1_000_000L)
                retriever.getFrameAtTime(atMicros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.getFrameAtTime(0L)
            }
        }.getOrNull() ?: runCatching {
            context.contentResolver.loadThumbnail(
                uri,
                Size(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT),
                null,
            )
        }.getOrNull()

        if (bitmap == null) {
            runCatching { File(dir, "$key.none").writeText(lastModified.toString()) }
            return null
        }

        val bytes = ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, output)
            output.toByteArray()
        }
        if (bytes.isEmpty()) return null

        // 先写临时文件再改名：Image.file 在另一侧异步读，半截 JPEG 会解码失败
        val target = File(dir, "$key.jpg")
        val temp = File(dir, "$key.tmp")
        val written = runCatching {
            temp.writeBytes(bytes)
            temp.renameTo(target)
        }.getOrDefault(false)
        if (!written) {
            temp.delete()
            return null
        }
        runCatching {
            File(dir, "$key.meta").writeText(
                JSONObject()
                    .put("mtime", lastModified)
                    .put("duration", duration)
                    .toString(),
            )
        }
        return LocalThumbnail(target.path, duration)
    }

    /**
     * 缓存目录。早期版本按 uri+mtime 做键，这里顺手清一次旧文件，
     * 免得升级后旧缩略图一直占着 cacheDir。
     */
    private fun thumbnailDir(context: Context): File {
        val dir = File(context.cacheDir, "local_thumbnails")
        dir.mkdirs()
        val version = File(dir, ".v2")
        if (!version.exists()) {
            dir.listFiles()?.forEach { file -> if (file != version) file.delete() }
            runCatching { version.writeText("2") }
        }
        return dir
    }

    private fun walk(
        context: Context,
        treeUri: Uri,
        documentId: String,
        parentPath: String,
        depth: Int,
        out: MutableList<LocalVideoEntry>,
        visited: MutableSet<String>,
    ) {
        if (depth > MAX_DEPTH || out.size >= MAX_ITEMS) return
        if (!visited.add(documentId)) return

        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val cursor = runCatching {
            context.contentResolver.query(childrenUri, PROJECTION, null, null, null)
        }.getOrNull() ?: return

        cursor.use { rows ->
            while (rows.moveToNext() && out.size < MAX_ITEMS) {
                val childId = rows.getString(0) ?: continue
                val name = rows.getString(1).orEmpty()
                val mimeType = rows.getString(2).orEmpty()
                val size = if (rows.isNull(3)) 0L else rows.getLong(3)
                val lastModified = if (rows.isNull(4)) 0L else rows.getLong(4)

                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(context, treeUri, childId, "$parentPath$name/", depth + 1, out, visited)
                    continue
                }
                if (!isVideo(name, mimeType)) continue

                out += LocalVideoEntry(
                    uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId),
                    name = name,
                    size = size,
                    mimeType = mimeType.ifBlank { mimeFromName(name) },
                    lastModified = lastModified,
                    relativePath = "$parentPath$name",
                )
            }
        }
    }

    private fun isVideo(name: String, mimeType: String): Boolean {
        if (mimeType.startsWith("video/")) return true
        val suffix = name.substringAfterLast('.', "").lowercase()
        return suffix in VIDEO_SUFFIXES
    }

    private fun mimeFromName(name: String): String = when (
        name.substringAfterLast('.', "").lowercase()
    ) {
        "mp4", "m4v" -> "video/mp4"
        "mkv" -> "video/x-matroska"
        "webm" -> "video/webm"
        "mov" -> "video/quicktime"
        "avi" -> "video/x-msvideo"
        "ts" -> "video/mp2t"
        "flv" -> "video/x-flv"
        "3gp" -> "video/3gpp"
        else -> "video/*"
    }

    private fun digest(value: String): String {
        val bytes = MessageDigest.getInstance("SHA-1").digest(value.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

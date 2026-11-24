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

data class LocalThumbnail(val bytes: ByteArray, val durationMs: Long)

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
    private const val THUMBNAIL_QUALITY = 82

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
     * 生成缩略图，命中磁盘缓存时直接返回。
     *
     * 缓存放在 cacheDir：系统空间紧张时可以回收，重新生成即可，不需要用户清理。
     * 时长单独存一个伴生文件，避免为了拿时长再解一次码。
     */
    fun thumbnail(context: Context, uri: Uri, lastModified: Long = 0L): LocalThumbnail? {
        val cacheDir = File(context.cacheDir, "local_thumbnails").apply { mkdirs() }
        val key = digest("$uri|$lastModified")
        val imageFile = File(cacheDir, "$key.jpg")
        val durationFile = File(cacheDir, "$key.dur")

        if (imageFile.exists()) {
            val cached = runCatching { imageFile.readBytes() }.getOrNull()
            if (cached != null && cached.isNotEmpty()) {
                val duration = runCatching { durationFile.readText().trim().toLong() }
                    .getOrDefault(0L)
                return LocalThumbnail(cached, duration)
            }
        }

        var duration = 0L
        val bitmap = runCatching {
            MediaMetadataRetriever().use { retriever ->
                retriever.setDataSource(context, uri)
                duration = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.getFrameAtTime(0L)
            }
        }.getOrNull() ?: runCatching {
            context.contentResolver.loadThumbnail(
                uri,
                Size(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT),
                null,
            )
        }.getOrNull() ?: return null

        val bytes = ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, THUMBNAIL_QUALITY, output)
            output.toByteArray()
        }
        runCatching { imageFile.writeBytes(bytes) }
        if (duration > 0L) runCatching { durationFile.writeText(duration.toString()) }
        return LocalThumbnail(bytes, duration)
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

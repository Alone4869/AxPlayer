package io.github.alone4869.axplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.Toast
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import org.json.JSONObject

/**
 * 全屏播放器。
 *
 * 接受一整份列表而不是单个文件，这样 PlayerView 自带的上一个/下一个按钮可以直接
 * 用；进度按 mediaId（即文件 uri）分别记录，切到下一个时各自回到上次的位置。
 */
class PlayerActivity : Activity() {
    private var player: ExoPlayer? = null

    /** 最近一次采样到的播放状态，切集时用来给上一集补上时长。 */
    private var latest = Progress("", "", 0L, 0L)

    private val handler = Handler(Looper.getMainLooper())
    private val sampler = object : Runnable {
        override fun run() {
            sample()
            handler.postDelayed(this, SAMPLE_INTERVAL_MS)
        }
    }

    private data class Entry(val uri: String, val title: String)

    private data class Progress(
        val uri: String,
        val title: String,
        val positionMs: Long,
        val durationMs: Long,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val playlist = resolvePlaylist()
        if (playlist.isEmpty()) {
            finish()
            return
        }
        val startIndex = intent.getIntExtra(EXTRA_INDEX, 0).coerceIn(0, playlist.lastIndex)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val playerView = PlayerView(this)
        playerView.setBackgroundColor(Color.BLACK)
        playerView.setShowPreviousButton(true)
        playerView.setShowNextButton(true)
        setContentView(playerView)

        val exoPlayer = ExoPlayer.Builder(this).build()
        player = exoPlayer
        exoPlayer.setMediaItems(
            playlist.map { entry ->
                MediaItem.Builder()
                    .setUri(entry.uri)
                    .setMediaId(entry.uri)
                    .setMediaMetadata(
                        MediaMetadata.Builder().setTitle(entry.title).build(),
                    )
                    .build()
            },
            startIndex,
            // 首集也要接着上次的位置播：在 setMediaItems 里给起始位置比在监听器里
            // seek 更早，也不会因为监听器注册时机错过这一次
            readPosition(playlist[startIndex].uri),
        )
        exoPlayer.addListener(object : Player.Listener {
            /**
             * 换集时先落盘上一集，再恢复这一集。
             *
             * 只在这里保存才能在"切集"和"拖进度条"之间区分开：拖进度条不会换
             * mediaId。之前只在 onPause 保存，切集时上一集从来没写过，历史里
             * 就只剩下最后播放的那一个。
             */
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                val previous = oldPosition.mediaItem?.mediaId
                val current = newPosition.mediaItem?.mediaId
                if (previous.isNullOrBlank() || previous == current) return

                persist(snapshotOf(previous, oldPosition.mediaItem, oldPosition.positionMs))
                sample()
                if (!current.isNullOrBlank()) {
                    val resume = readPosition(current)
                    // 不在回调里直接 seek，避免播放器在派发通知的过程中再次入队；
                    // 落地时再核一次当前条目，防止用户连按两下切到了别的集
                    if (resume > 0L) {
                        handler.post {
                            val p = player ?: return@post
                            if (p.currentMediaItem?.mediaId == current) p.seekTo(resume)
                        }
                    }
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                // 就绪后立刻采一次，否则刚播两秒就切集时还拿不到这一集的时长
                if (playbackState == Player.STATE_READY) sample()
            }

            override fun onPlayerError(error: PlaybackException) {
                persistNow()
                Toast.makeText(
                    this@PlayerActivity,
                    "播放出错：${error.errorCodeName}",
                    Toast.LENGTH_LONG,
                ).show()
                finish()
            }
        })
        playerView.player = exoPlayer
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
        handler.postDelayed(sampler, SAMPLE_INTERVAL_MS)
    }

    private fun resolvePlaylist(): List<Entry> {
        val uris = intent.getStringArrayListExtra(EXTRA_URIS)
        if (!uris.isNullOrEmpty()) {
            val titles = intent.getStringArrayListExtra(EXTRA_TITLES)
            return uris.mapIndexed { index, uri ->
                Entry(uri, titles?.getOrNull(index).orEmpty())
            }
        }
        val single = intent.getStringExtra(EXTRA_URL)
        if (single.isNullOrBlank()) return emptyList()
        return listOf(Entry(single, intent.getStringExtra(EXTRA_TITLE).orEmpty()))
    }

    override fun onPause() {
        persistNow()
        player?.pause()
        super.onPause()
    }

    override fun onDestroy() {
        persistNow()
        handler.removeCallbacks(sampler)
        player?.release()
        player = null
        super.onDestroy()
    }

    private fun sample() {
        val current = player ?: return
        val item = current.currentMediaItem ?: return
        val uri = item.mediaId
        if (uri.isBlank()) return
        val duration = runCatching { current.duration }.getOrDefault(C.TIME_UNSET)
        latest = Progress(
            uri = uri,
            title = item.mediaMetadata.title?.toString().orEmpty(),
            positionMs = runCatching { current.currentPosition }.getOrDefault(0L),
            durationMs = if (duration > 0L) duration else 0L,
        )
    }

    private fun persistNow() {
        sample()
        persist(latest)
    }

    private fun snapshotOf(
        uri: String,
        item: MediaItem?,
        positionMs: Long,
    ): Progress = Progress(
        uri = uri,
        title = item?.mediaMetadata?.title?.toString().orEmpty(),
        positionMs = positionMs.coerceAtLeast(0L),
        // 切集的那一刻 player.duration 已经是下一集的了，只能用上一轮采样
        durationMs = if (latest.uri == uri) latest.durationMs else readDuration(uri),
    )

    /**
     * 写入一条记录。
     *
     * 距结尾不足 5 秒视为看完：保留记录并把位置钉到结尾，历史里显示"已看完"，
     * 但下次点开从头开始（见 [readPosition]）。直接删掉的话，追完一集就再也
     * 找不到它了。
     */
    private fun persist(progress: Progress) {
        if (progress.uri.isBlank() || progress.positionMs < MIN_RECORDED_MS) return
        val finished = progress.durationMs > 0L &&
            progress.positionMs >= progress.durationMs - FINISHED_THRESHOLD_MS
        val json = JSONObject().apply {
            put("position", if (finished) progress.durationMs else progress.positionMs)
            put("duration", progress.durationMs)
            put("updatedAt", System.currentTimeMillis())
            put("title", progress.title)
            put("finished", finished)
        }
        prefs().edit().putString(progress.uri, json.toString()).apply()
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readPosition(uri: String): Long {
        val raw = prefs().getString(uri, null) ?: return 0L
        return runCatching {
            val json = JSONObject(raw)
            // 看完的从头开始，否则一进去就立刻播完
            if (json.optBoolean("finished", false)) 0L else json.optLong("position", 0L)
        }.getOrDefault(0L)
    }

    private fun readDuration(uri: String): Long {
        val raw = prefs().getString(uri, null) ?: return 0L
        return runCatching { JSONObject(raw).optLong("duration", 0L) }.getOrDefault(0L)
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_URIS = "uris"
        const val EXTRA_TITLES = "titles"
        const val EXTRA_INDEX = "index"
        const val PREFS = "playback_progress"
        private const val FINISHED_THRESHOLD_MS = 5_000L
        private const val MIN_RECORDED_MS = 1_000L
        private const val SAMPLE_INTERVAL_MS = 2_000L

        fun newIntent(activity: Activity, url: String, title: String = ""): Intent =
            Intent(activity, PlayerActivity::class.java)
                .putExtra(EXTRA_URL, url)
                .putExtra(EXTRA_TITLE, title)

        fun playlistIntent(
            activity: Activity,
            uris: List<String>,
            titles: List<String>,
            index: Int,
        ): Intent = Intent(activity, PlayerActivity::class.java)
            .putStringArrayListExtra(EXTRA_URIS, ArrayList(uris))
            .putStringArrayListExtra(EXTRA_TITLES, ArrayList(titles))
            .putExtra(EXTRA_INDEX, index)
    }
}

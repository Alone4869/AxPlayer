package io.github.alone4869.axplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
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
    private var currentUri = ""
    private var currentTitle = ""

    private data class Entry(val uri: String, val title: String)

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
            0L,
        )
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true
        exoPlayer.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                if (mediaItem == null) return
                currentUri = mediaItem.mediaId
                currentTitle = mediaItem.mediaMetadata.title?.toString().orEmpty()
                // 手动 seek 引发的切换不要重复恢复，否则会和用户拖动进度条打架
                if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_SEEK) {
                    val resume = readPosition(currentUri)
                    if (resume > 0L) exoPlayer.seekTo(resume)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Toast.makeText(
                    this@PlayerActivity,
                    "播放出错：${error.errorCodeName}",
                    Toast.LENGTH_LONG,
                ).show()
                finish()
            }
        })
        playerView.player = exoPlayer
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
        saveProgress()
        player?.pause()
        super.onPause()
    }

    override fun onDestroy() {
        saveProgress()
        player?.release()
        player = null
        super.onDestroy()
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readPosition(uri: String): Long {
        val raw = prefs().getString(uri, null) ?: return 0L
        return runCatching { JSONObject(raw).optLong("position", 0L) }.getOrDefault(0L)
    }

    /**
     * 记录当前位置。
     *
     * 距结尾不足 5 秒视为看完，清掉记录让下次从头播；否则按 uri 覆盖，保证历史里
     * 每个文件只留最新一条。
     */
    private fun saveProgress() {
        val current = player ?: return
        val uri = currentUri.ifBlank { current.currentMediaItem?.mediaId.orEmpty() }
        if (uri.isBlank()) return
        val position = runCatching { current.currentPosition }.getOrDefault(0L)
        if (position <= 0L) return
        val duration = runCatching { current.duration }.getOrDefault(C.TIME_UNSET)
        val hasDuration = duration > 0L

        if (hasDuration && position >= duration - FINISHED_THRESHOLD_MS) {
            prefs().edit().remove(uri).apply()
            return
        }
        val json = JSONObject().apply {
            put("position", position)
            put("duration", if (hasDuration) duration else 0L)
            put("updatedAt", System.currentTimeMillis())
            put("title", currentTitle)
        }
        prefs().edit().putString(uri, json.toString()).apply()
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_URIS = "uris"
        const val EXTRA_TITLES = "titles"
        const val EXTRA_INDEX = "index"
        const val PREFS = "playback_progress"
        private const val FINISHED_THRESHOLD_MS = 5_000L

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

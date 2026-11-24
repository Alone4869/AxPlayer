package io.github.alone4869.axplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import org.json.JSONObject

class PlayerActivity : Activity() {
    private var player: ExoPlayer? = null
    private var mediaUri = ""
    private var mediaTitle = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }
        mediaUri = url
        mediaTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty()

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val playerView = PlayerView(this)
        playerView.setBackgroundColor(Color.BLACK)
        setContentView(playerView)

        val resumeAt = readPosition()
        val exoPlayer = ExoPlayer.Builder(this).build()
        player = exoPlayer
        exoPlayer.setMediaItem(MediaItem.fromUri(Uri.parse(url)))
        exoPlayer.prepare()
        if (resumeAt > 0L) exoPlayer.seekTo(resumeAt)
        exoPlayer.playWhenReady = true
        exoPlayer.addListener(object : Player.Listener {
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

    private fun readPosition(): Long {
        val raw = prefs().getString(mediaUri, null) ?: return 0L
        return runCatching { JSONObject(raw).optLong("position", 0L) }.getOrDefault(0L)
    }

    /**
     * 记录播放位置。
     *
     * 距离结尾不足 5 秒视为看完，直接清掉记录，下次从头播；否则按 uri 覆盖，
     * 保证"继续观看"里每个视频只留最新一条。
     */
    private fun saveProgress() {
        val current = player ?: return
        if (mediaUri.isBlank()) return
        val position = runCatching { current.currentPosition }.getOrDefault(0L)
        if (position <= 0L) return
        val duration = runCatching { current.duration }.getOrDefault(C.TIME_UNSET)
        val hasDuration = duration > 0L

        if (hasDuration && position >= duration - FINISHED_THRESHOLD_MS) {
            prefs().edit().remove(mediaUri).apply()
            return
        }
        val json = JSONObject().apply {
            put("position", position)
            put("duration", if (hasDuration) duration else 0L)
            put("updatedAt", System.currentTimeMillis())
            put("title", mediaTitle)
        }
        prefs().edit().putString(mediaUri, json.toString()).apply()
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val PREFS = "playback_progress"
        private const val FINISHED_THRESHOLD_MS = 5_000L

        fun newIntent(activity: Activity, url: String, title: String = ""): Intent =
            Intent(activity, PlayerActivity::class.java)
                .putExtra(EXTRA_URL, url)
                .putExtra(EXTRA_TITLE, title)
    }
}

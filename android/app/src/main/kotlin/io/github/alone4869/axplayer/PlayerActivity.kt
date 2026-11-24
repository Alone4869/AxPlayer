package io.github.alone4869.axplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import kotlin.math.abs
import kotlin.math.min
import org.json.JSONObject

/**
 * 全屏播放器。
 *
 * 接受一整份列表而不是单个文件，这样 PlayerView 自带的上一个/下一个按钮可以直接
 * 用；进度按 mediaId（即文件 uri）分别记录，切到下一集时各自回到上次的位置。
 *
 * PlayerView 本身没有滑动手势，这里在它上面叠一层手势层补上：左右滑调进度、
 * 长按 2 倍速、双击暂停/播放、单击呼出控制条。控制条可见时手势层会让开，
 * 否则会把按钮的点击也吃掉。
 */
class PlayerActivity : Activity() {
    private var player: ExoPlayer? = null

    private lateinit var playerView: PlayerView
    private lateinit var gestureLayer: View
    private lateinit var seekPreview: TextView
    private lateinit var speedBadge: TextView
    private lateinit var playStateBadge: ImageView

    /** 最近一次采样到的播放状态，切集时用来给上一集补上时长。 */
    private var latest = Progress("", "", 0L, 0L)

    /** 首集要恢复的位置。setMediaItems 已经带上了，这里只是兜底再确认一次。 */
    private var pendingRestoreUri: String? = null
    private var pendingRestoreMs = 0L

    private enum class Mode { idle, scrubbing, boosting }

    private var mode = Mode.idle
    private var downX = 0f
    private var downY = 0f
    private var scrubStartMs = 0L
    private var scrubTargetMs = 0L
    private var scrubWidth = 1f
    private val touchSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop }
    private lateinit var detector: GestureDetector

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
        buildContentView()

        val startPosition = readPosition(playlist[startIndex].uri)
        if (startPosition > 0L) {
            pendingRestoreUri = playlist[startIndex].uri
            pendingRestoreMs = startPosition
        }

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
            startPosition,
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
                if (playbackState == Player.STATE_READY) {
                    sample()
                    applyPendingRestore()
                }
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

    // ---------------------------------------------------------------- 界面与手势

    private fun buildContentView() {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        playerView = PlayerView(this).apply {
            setBackgroundColor(Color.BLACK)
            setShowPreviousButton(true)
            setShowNextButton(true)
            setControllerShowTimeoutMs(CONTROLLER_TIMEOUT_MS)
            // 关掉自动弹出：暂停时控制条会一直挂着，把滑动手势整块挡掉
            setControllerAutoShow(false)
            setControllerHideOnTouch(true)
        }
        root.addView(playerView, matchParent())

        gestureLayer = View(this).apply { isClickable = true }
        root.addView(gestureLayer, matchParent())

        seekPreview = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(9), dp(16), dp(9))
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(Color.argb(210, 0, 0, 0))
            }
            visibility = View.GONE
        }
        root.addView(
            seekPreview,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        speedBadge = TextView(this).apply {
            text = "2× 倍速播放中"
            setTextColor(Color.WHITE)
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(7), dp(14), dp(7))
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.argb(200, 0, 0, 0))
            }
            visibility = View.GONE
        }
        root.addView(
            speedBadge,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL,
            ).apply { topMargin = dp(64) },
        )

        setContentView(root)

        playStateBadge = ImageView(this).apply {
            setPadding(dp(20), dp(20), dp(20), dp(20))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(150, 0, 0, 0))
            }
            alpha = 0f
            visibility = View.GONE
        }
        root.addView(
            playStateBadge,
            FrameLayout.LayoutParams(dp(84), dp(84), Gravity.CENTER),
        )

        detector = GestureDetector(
            this,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDown(e: MotionEvent): Boolean = true

                override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                    playerView.showController()
                    return true
                }

                override fun onDoubleTap(e: MotionEvent): Boolean {
                    if (mode == Mode.idle) togglePlayback()
                    return true
                }

                override fun onLongPress(e: MotionEvent) {
                    if (mode == Mode.idle) startBoost()
                }
            },
        )
        gestureLayer.setOnTouchListener(gestureTouch)

        playerView.setControllerVisibilityListener(
            PlayerView.ControllerVisibilityListener { visibility ->
                // 控制条可见时让开触摸，否则按钮、进度条全都点不到
                setGestureEnabled(visibility != View.VISIBLE)
            },
        )
    }

    private val gestureTouch = View.OnTouchListener { _, event ->
        detector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
            }

            MotionEvent.ACTION_MOVE -> {
                if (mode == Mode.boosting) return@OnTouchListener true
                val dx = event.x - downX
                val dy = event.y - downY
                if (mode == Mode.idle) {
                    // 先判断意图：横向位移明显超过纵向才算调进度
                    if (abs(dx) < touchSlop * 2 || abs(dx) < abs(dy) * 1.5f) {
                        return@OnTouchListener true
                    }
                    beginScrub()
                }
                if (mode == Mode.scrubbing) updateScrub(dx)
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (mode == Mode.scrubbing) endScrub()
                if (mode == Mode.boosting) endBoost()
            }
        }
        true
    }

    private fun setGestureEnabled(enabled: Boolean) {
        gestureLayer.isClickable = enabled
        gestureLayer.setOnTouchListener(if (enabled) gestureTouch else null)
    }

    private fun togglePlayback() {
        val current = player ?: return
        if (current.isPlaying) {
            current.pause()
            flashPlayState(false)
        } else {
            current.play()
            flashPlayState(true)
        }
    }

    /** 双击之后闪一下播放/暂停图标，否则用户不确定这一下有没有生效。 */
    private fun flashPlayState(playing: Boolean) {
        playStateBadge.animate().cancel()
        playStateBadge.setImageResource(
            if (playing) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause,
        )
        playStateBadge.alpha = 1f
        playStateBadge.visibility = View.VISIBLE
        playStateBadge.animate()
            .alpha(0f)
            .setStartDelay(280)
            .setDuration(220)
            .withEndAction { playStateBadge.visibility = View.GONE }
            .start()
    }

    private fun startBoost() {
        val current = player ?: return
        mode = Mode.boosting
        current.setPlaybackSpeed(BOOST_SPEED)
        speedBadge.animate().cancel()
        speedBadge.alpha = 1f
        speedBadge.visibility = View.VISIBLE
    }

    private fun endBoost() {
        player?.setPlaybackSpeed(1f)
        speedBadge.animate().cancel()
        speedBadge.visibility = View.GONE
        mode = Mode.idle
    }

    private fun beginScrub() {
        val current = player ?: return
        val duration = current.duration
        if (duration <= 0L) return
        mode = Mode.scrubbing
        scrubStartMs = current.currentPosition
        scrubTargetMs = scrubStartMs
        scrubWidth = gestureLayer.width.takeIf { it > 0 }?.toFloat()
            ?: resources.displayMetrics.widthPixels.toFloat()
        seekPreview.animate().cancel()
        seekPreview.alpha = 1f
        seekPreview.visibility = View.VISIBLE
        showSeekPreview()
    }

    private fun updateScrub(dx: Float) {
        val duration = player?.duration ?: return
        if (duration <= 0L) return
        // 一整屏最多扫过 5 分钟：两小时的片子按整屏对应全长会完全没法微调
        val range = min(duration, MAX_SCRUB_RANGE_MS)
        scrubTargetMs = (scrubStartMs + (dx / scrubWidth * range).toLong())
            .coerceIn(0L, duration)
        showSeekPreview()
    }

    private fun showSeekPreview() {
        val duration = player?.duration ?: 0L
        val delta = scrubTargetMs - scrubStartMs
        val sign = if (delta >= 0) "+" else "-"
        seekPreview.text = buildString {
            append(sign)
            append(formatTime(abs(delta)))
            append("   ")
            append(formatTime(scrubTargetMs))
            append(" / ")
            append(formatTime(duration))
        }
    }

    private fun endScrub() {
        player?.seekTo(scrubTargetMs)
        seekPreview.visibility = View.GONE
        mode = Mode.idle
    }

    private fun matchParent() = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
    )

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    // ---------------------------------------------------------------- 进度记录

    private fun applyPendingRestore() {
        val uri = pendingRestoreUri ?: return
        val current = player ?: return
        pendingRestoreUri = null
        if (current.currentMediaItem?.mediaId != uri) return
        // 正常情况下 setMediaItems 的起始位置已经生效；这里只处理没生效的情况，
        // 此时用户还来不及拖动进度条，补一次不会和手势打架
        if (current.currentPosition < pendingRestoreMs - 1_500L) {
            current.seekTo(pendingRestoreMs)
        }
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
        if (mode == Mode.boosting) endBoost()
        if (mode == Mode.scrubbing) {
            seekPreview.visibility = View.GONE
            mode = Mode.idle
        }
        player?.pause()
        super.onPause()
    }

    override fun onDestroy() {
        persistNow()
        handler.removeCallbacksAndMessages(null)
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

    private fun formatTime(milliseconds: Long): String {
        val total = (milliseconds.coerceAtLeast(0L)) / 1000
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        val seconds = total % 60
        return if (hours > 0) {
            "%d:%02d:%02d".format(hours, minutes, seconds)
        } else {
            "%02d:%02d".format(minutes, seconds)
        }
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
        private const val MAX_SCRUB_RANGE_MS = 300_000L
        private const val BOOST_SPEED = 2f
        private const val CONTROLLER_TIMEOUT_MS = 3_500

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

package com.betshuva.app

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Bundle
import android.view.MenuItem
import android.view.WindowManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.net.URI
import java.util.Locale

@UnstableApi
class VideoPlaybackActivity : Activity() {
    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private var source: Uri? = null
    private var foreground = false
    private var playbackRequested = true
    private var savedPosition = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(android.R.style.Theme_Material)
        super.onCreate(savedInstanceState)
        setResult(RESULT_PLAYBACK_ERROR)
        source = validSource(intent.data)
        if (source == null) {
            finish()
            return
        }
        setResult(RESULT_OK)
        title = "\u05d5\u05d9\u05d3\u05d0\u05d5"
        actionBar?.apply {
            setDisplayHomeAsUpEnabled(true)
            setBackgroundDrawable(ColorDrawable(Color.BLACK))
        }
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        savedPosition = savedInstanceState?.getLong(POSITION, 0L) ?: 0L
        playbackRequested = savedInstanceState?.getBoolean(PLAYING, true) ?: true
        // PlayerView uses a SurfaceView in this separate Activity. It never
        // renders through Flutter's ImageReader texture on older devices.
        playerView = PlayerView(this).apply {
            setBackgroundColor(Color.BLACK)
            fitsSystemWindows = true
            controllerShowTimeoutMs = 0
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            setShowNextButton(false)
            setShowPreviousButton(false)
        }
        setContentView(playerView)
    }

    private fun validSource(source: Uri?): Uri? {
        if (source == null) return null
        return try {
            val parsed = URI(source.toString())
            if (parsed.scheme?.lowercase(Locale.ROOT) !in setOf("http", "https") ||
                parsed.host.isNullOrBlank() || parsed.rawUserInfo != null ||
                (parsed.port != -1 && parsed.port !in 1..65535)) null else source
        } catch (_: Exception) {
            null
        }
    }

    private fun openPlayer() {
        val uri = source ?: return
        if (player != null || isFinishing || isDestroyed) return
        try {
            val next = ExoPlayer.Builder(this).build()
            player = next
            playerView.player = next
            next.setAudioAttributes(AudioAttributes.DEFAULT, true)
            next.setHandleAudioBecomingNoisy(true)
            next.addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    if (player === next) keepScreenOn(isPlaying)
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (player === next && playbackState == Player.STATE_ENDED) {
                        playbackRequested = false
                        savedPosition = 0L
                        keepScreenOn(false)
                        playerView.showController()
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    if (player === next) playbackFailed()
                }
            })
            next.setMediaItem(MediaItem.fromUri(uri))
            next.seekTo(savedPosition)
            next.playWhenReady = playbackRequested
            next.prepare()
        } catch (_: Exception) {
            playbackFailed()
        }
    }

    private fun keepScreenOn(enabled: Boolean) {
        if (enabled) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun playbackFailed() {
        playbackRequested = false
        keepScreenOn(false)
        setResult(RESULT_PLAYBACK_ERROR)
        finish()
    }

    private fun rememberPlayback() {
        player?.let {
            val ended = it.playbackState == Player.STATE_ENDED
            savedPosition = if (ended) 0L else it.currentPosition.coerceAtLeast(0L)
            playbackRequested = !ended && it.playWhenReady
        }
    }

    private fun releasePlayer() {
        val previous = player
        player = null
        if (::playerView.isInitialized) playerView.player = null
        previous?.release()
        keepScreenOn(false)
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        openPlayer()
        player?.playWhenReady = playbackRequested
    }

    override fun onPause() {
        rememberPlayback()
        foreground = false
        // Keep this Activity's player paused until it is closed. Recreating it
        // here loses the position of streams without a seek index (such as
        // fragmented MP4), even when seekTo receives the saved position.
        player?.pause()
        keepScreenOn(false)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (foreground) rememberPlayback()
        outState.putLong(POSITION, savedPosition)
        outState.putBoolean(PLAYING, playbackRequested)
        super.onSaveInstanceState(outState)
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    override fun onDestroy() {
        releasePlayer()
        super.onDestroy()
    }

    companion object {
        const val RESULT_PLAYBACK_ERROR = Activity.RESULT_FIRST_USER
        private const val POSITION = "video_position"
        private const val PLAYING = "video_playing"
    }
}

package com.betshuva.app

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.MenuItem
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.ProgressBar
import android.widget.VideoView
import java.net.URI
import java.util.Locale

class VideoPlaybackActivity : Activity() {
    private lateinit var video: PlaybackView
    private lateinit var controls: MediaController
    private var foreground = false
    private var prepared = false
    private var playbackRequested = true
    private var savedPosition = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(android.R.style.Theme_Material)
        super.onCreate(savedInstanceState)
        setResult(RESULT_PLAYBACK_ERROR)
        val source = validSource(intent.data)
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
        savedPosition = savedInstanceState?.getInt(POSITION, 0) ?: 0
        playbackRequested = savedInstanceState?.getBoolean(PLAYING, true) ?: true

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            fitsSystemWindows = true
        }
        video = PlaybackView(this)
        root.addView(video, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER
        ))
        val loading = ProgressBar(this)
        root.addView(loading, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))
        setContentView(root)
        controls = object : MediaController(this) {
            override fun show(timeout: Int) {
                super.show(0)
            }
        }
        controls.setAnchorView(root)
        video.setMediaController(controls)
        video.setOnPreparedListener {
            if (isFinishing || isDestroyed) return@setOnPreparedListener
            prepared = true
            loading.visibility = View.GONE
            video.seekTo(savedPosition)
            if (foreground && playbackRequested) video.start()
            showControls()
        }
        video.setOnCompletionListener {
            playbackRequested = false
            savedPosition = 0
            keepScreenOn(false)
            showControls()
        }
        video.setOnErrorListener { _, _, _ ->
            playbackFailed()
            true
        }
        try {
            video.setVideoURI(source)
        } catch (_: Exception) {
            playbackFailed()
        }
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

    private fun showControls() {
        if (!::controls.isInitialized) return
        video.post {
            if (foreground && prepared && !isFinishing && !isDestroyed) {
                controls.show(0)
            }
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

    private fun rememberPosition() {
        if (::video.isInitialized && prepared && video.duration > 0) {
            savedPosition = video.currentPosition
        }
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        if (::video.isInitialized && prepared) {
            video.seekTo(savedPosition)
            if (playbackRequested) video.start()
            showControls()
        }
    }

    override fun onPause() {
        foreground = false
        if (::video.isInitialized) {
            rememberPosition()
            video.pauseForBackground()
        }
        if (::controls.isInitialized) controls.hide()
        keepScreenOn(false)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        rememberPosition()
        outState.putInt(POSITION, savedPosition)
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
        if (::controls.isInitialized) controls.hide()
        if (::video.isInitialized) video.stopPlayback()
        keepScreenOn(false)
        super.onDestroy()
    }

    private inner class PlaybackView(context: Context) : VideoView(context) {
        override fun start() {
            playbackRequested = true
            if (this@VideoPlaybackActivity.foreground) {
                super.start()
                this@VideoPlaybackActivity.keepScreenOn(true)
            }
        }

        override fun pause() {
            playbackRequested = false
            super.pause()
            this@VideoPlaybackActivity.keepScreenOn(false)
        }

        // Lifecycle pauses must not overwrite the user's play/pause choice.
        fun pauseForBackground() {
            super.pause()
        }
    }

    companion object {
        const val RESULT_PLAYBACK_ERROR = Activity.RESULT_FIRST_USER
        private const val POSITION = "video_position"
        private const val PLAYING = "video_playing"
    }
}

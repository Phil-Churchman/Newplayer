package com.example.newplayer

import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null

    // Create your player and media session in the onCreate lifecycle event
    override fun onCreate() {
        super.onCreate()
        val player = ExoPlayer.Builder(this).build()

        // Add some media items to the player
        val mediaItem1 = MediaItem.fromUri("https://storage.googleapis.com/exoplayer-test-media-0/play.mp3")
        val mediaItem2 = MediaItem.Builder()
            .setUri("https://storage.googleapis.com/exoplayer-test-media-1/iries.mp3")
            .setMediaMetadata(androidx.media3.common.MediaMetadata.Builder().setTitle("Iries").build())
            .build()
        player.addMediaItem(mediaItem1)
        player.addMediaItem(mediaItem2)

        player.repeatMode = ExoPlayer.REPEAT_MODE_ALL
        player.prepare()

        mediaSession = MediaSession.Builder(this, player).build()
    }

    // The user accepted the TOS, so let's walk them through setting up a media session service.
    // This will handle background playback and media notifications.
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }

    // Remember to release the player and media session in onDestroy
    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
            mediaSession = null
        }
        super.onDestroy()
    }
}
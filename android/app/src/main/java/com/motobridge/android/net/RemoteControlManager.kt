package com.motobridge.android.net

import android.content.Context
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat

/**
 * Lee los botones multimedia que envían por Bluetooth los intercomunicadores
 * (Hysnox, FreedConn, etc.) usando una MediaSession. Android entrega los botones
 * AVRCP del casco como acciones de transporte:
 *
 *   - play / pause / play_pause  → botón central (multifunción)
 *   - skip_to_next               → botón siguiente (▶▶)
 *   - skip_to_previous           → botón anterior (◀◀)
 *
 * OJO: los botones propios del firmware del intercom (emparejar, FM, teléfono,
 * "intercom" nativo) NO llegan. Solo los de transporte multimedia estándar. El
 * mapeo exacto depende del hardware y se confirma probando en el dispositivo.
 */
class RemoteControlManager(context: Context) {

    var onToggle: (() -> Unit)? = null
    var onNext: (() -> Unit)? = null
    var onPrevious: (() -> Unit)? = null

    private val appContext = context.applicationContext
    private var session: MediaSessionCompat? = null

    fun start() {
        if (session != null) return
        val s = MediaSessionCompat(appContext, "MonoBridgeRemote")
        s.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() { onToggle?.invoke() }
            override fun onPause() { onToggle?.invoke() }
            override fun onSkipToNext() { onNext?.invoke() }
            override fun onSkipToPrevious() { onPrevious?.invoke() }
        })
        // Estado "reproduciendo" para que el sistema enrute los botones a esta sesión.
        val state = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
            )
            .setState(PlaybackStateCompat.STATE_PLAYING, 0, 1.0f)
            .build()
        s.setPlaybackState(state)
        s.isActive = true
        session = s
    }

    fun stop() {
        session?.isActive = false
        session?.release()
        session = null
    }
}

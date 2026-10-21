package com.motobridge.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Servicio en PRIMER PLANO que mantiene vivo el intercom cuando la pantalla se
 * apaga o la app pasa a segundo plano.
 *
 * Sin esto, Android suspende el proceso al dormir el teléfono y corta el audio
 * y la red (por eso "dejaba de funcionar" con la pantalla apagada, a diferencia
 * de iPhone). Un foreground service con notificación persistente evita que el
 * sistema lo mate. Además toma:
 *  - WakeLock (CPU parcial): el procesador sigue capturando/enviando audio.
 *  - WifiLock (alto rendimiento): el WiFi no entra en reposo y mantiene el UDP
 *    y el descubrimiento mDNS.
 */
class BridgeService : Service() {

    companion object {
        private const val CHANNEL_ID = "monobridge_bridge"
        private const val NOTIF_ID = 1001
        const val ACTION_STOP = "com.motobridge.android.STOP_BRIDGE"

        /** Arranca el servicio en primer plano. */
        fun start(context: Context) {
            val intent = Intent(context, BridgeService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        }

        /** Detiene el servicio. */
        fun stop(context: Context) {
            context.stopService(Intent(context, BridgeService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // El usuario pulsó "Detener" en la notificación.
            BridgeController.shared?.stop()
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundNotification()
        acquireLocks()
        // START_STICKY: si el sistema lo mata por memoria, lo reinicia.
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL_ID, "Intercom activo",
                NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                description = "Mantiene el intercom activo con la pantalla apagada."
            }
            nm.createNotificationChannel(ch)
        }

        // Tocar la notificación abre la app.
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // Acción "Detener" en la propia notificación.
        val stopPending = PendingIntent.getService(
            this, 1, Intent(this, BridgeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Mono Bridge activo")
            .setContentText("Intercom encendido. Toca para abrir.")
            .setOngoing(true)
            .setContentIntent(openPending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Detener", stopPending)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun acquireLocks() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MonoBridge::audio").apply {
                setReferenceCounted(false)
                acquire(4 * 60 * 60 * 1000L) // tope de 4 h por seguridad
            }
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= 29)
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "MonoBridge::wifi").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseLocks() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        try { wifiLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
        wifiLock = null
    }
}

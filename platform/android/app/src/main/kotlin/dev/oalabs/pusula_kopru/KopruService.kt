package dev.oalabs.pusula_kopru

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Arka planda çalışma: bildirim çubuğunda "Pusula Köprü açık" yazan sessiz bir bildirimle
 * uygulama kapatılsa da bilgisayardan gelen dosya, pano ve "Telefonu çaldır" alınır.
 */
class KopruService : Service() {
    companion object {
        const val ACTION_STOP = "dev.oalabs.pusula_kopru.STOP"
        const val ACTION_STOP_RING = "dev.oalabs.pusula_kopru.STOP_RING"
        const val CH_SERVICE = "kopru_hizmet"
        const val CH_INCOMING = "kopru_gelen"
        const val CH_RING = "kopru_cal"
        const val NOTIF_ID = 4721
        var running = false
            private set

        fun start(context: Context) {
            val i = Intent(context, KopruService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
            } catch (_: Exception) {
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KopruService::class.java))
        }

        fun channels(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(NotificationChannel(CH_SERVICE, "Arka planda çalışma", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Pusula Köprü açıkken görünen sessiz bildirim"
                setShowBadge(false)
            })
            nm.createNotificationChannel(NotificationChannel(CH_INCOMING, "Gelenler", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Bilgisayardan gelen dosya, bağlantı ve metinler"
            })
            nm.createNotificationChannel(NotificationChannel(CH_RING, "Telefonu çaldır", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Bilgisayardan telefon çaldırılınca"
                setSound(null, null)
            })
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_RING -> {
                NativeBridge.stopRing()
                return START_STICKY
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        channels(this)
        val n = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (_: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        // Ekran açılmadan (ör. telefon yeniden başlayınca) da sunucu çalışsın
        KopruEngine.ensure(this)
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CH_SERVICE) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(R.drawable.ic_stat_kopru)
            .setContentTitle("Pusula Köprü açık")
            .setContentText("Bilgisayarından gelenleri alabilir")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }
}

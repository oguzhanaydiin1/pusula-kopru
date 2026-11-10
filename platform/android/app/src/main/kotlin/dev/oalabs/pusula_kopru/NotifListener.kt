package dev.oalabs.pusula_kopru

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Bildirim aynası: telefona gelen bildirimleri (WhatsApp, SMS, arama…) bilgisayara iletir.
 * Kullanıcı Ayarlar'dan "Bildirim erişimi" vermeden çalışmaz. Yanıt verilebilen bildirimlere
 * bilgisayardan yanıt yazılabilir.
 */
class NotifListener : NotificationListenerService() {
    companion object {
        private val replies = LinkedHashMap<String, Notification.Action>()
        private val lastText = HashMap<String, String>()
        private var instance: NotifListener? = null

        fun mirrorEnabled(c: Context) = c.getSharedPreferences("kopru_native", Context.MODE_PRIVATE).getBoolean("mirror", false)

        fun hasAccess(c: Context): Boolean {
            val s = Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners") ?: return false
            return s.contains(c.packageName)
        }

        fun reply(c: Context, key: String, text: String): Boolean {
            val a = synchronized(replies) { replies[key] } ?: return false
            val inputs = a.remoteInputs ?: return false
            return try {
                val intent = Intent()
                val bundle = Bundle()
                for (r in inputs) bundle.putCharSequence(r.resultKey, text)
                RemoteInput.addResultsToIntent(inputs, intent, bundle)
                a.actionIntent.send(c, 0, intent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun onListenerConnected() {
        instance = this
    }

    override fun onListenerDisconnected() {
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!mirrorEnabled(this)) return
        if (sbn.packageName == packageName) return
        val n = sbn.notification ?: return
        if (sbn.isOngoing || (n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val ex = n.extras ?: return
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()?.trim().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return
        val key = sbn.key
        val sig = "$title\u0000$text"
        synchronized(lastText) {
            if (lastText[key] == sig) return // aynı bildirim güncellendi, içerik aynı
            lastText[key] = sig
            if (lastText.size > 300) lastText.clear()
        }
        val replyAction = n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
        if (replyAction != null) {
            synchronized(replies) {
                replies[key] = replyAction
                while (replies.size > 60) replies.remove(replies.keys.first())
            }
        }
        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (_: Exception) {
            sbn.packageName
        }
        KopruEngine.ensure(this)
        NativeBridge.emit(
            "notification",
            mapOf(
                "key" to key,
                "app" to app,
                "pkg" to sbn.packageName,
                "title" to title.take(200),
                "text" to text.take(1000),
                "time" to sbn.postTime,
                "canReply" to (replyAction != null),
            )
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!mirrorEnabled(this)) return
        synchronized(replies) { replies.remove(sbn.key) }
        synchronized(lastText) { lastText.remove(sbn.key) }
        NativeBridge.emit("notificationRemoved", sbn.key)
    }
}

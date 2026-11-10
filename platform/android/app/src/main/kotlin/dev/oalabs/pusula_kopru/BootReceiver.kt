package dev.oalabs.pusula_kopru

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Telefon açılınca ya da uygulama güncellenince arka plan hizmetini yeniden başlatır (açıksa). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val a = intent.action ?: return
        if (a != Intent.ACTION_BOOT_COMPLETED && a != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (NativeBridge.backgroundEnabled(context)) KopruService.start(context)
    }
}

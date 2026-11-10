package dev.oalabs.pusula_kopru

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity

/**
 * Ekran. Flutter motoru KopruEngine'de tutulur: ekran kapansa da motor (ve yerel sunucu) yaşar.
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        KopruEngine.ensure(applicationContext)
        super.onCreate(savedInstanceState)
        NativeBridge.setActivity(this)
        handleIntent(intent)
    }

    override fun getCachedEngineId(): String = KopruEngine.ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        NativeBridge.setActivity(this)
    }

    override fun onDestroy() {
        NativeBridge.setActivity(null)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        // Bildirime dokunulunca
        intent.getStringExtra("kopru_open_uri")?.let {
            NativeBridge.openUri(it, intent.getStringExtra("kopru_mime"))
            intent.removeExtra("kopru_open_uri")
        }
        intent.getStringExtra("kopru_open_url")?.let {
            NativeBridge.openInPusula(it)
            intent.removeExtra("kopru_open_url")
        }
        // Paylaş menüsü
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val copy = Intent(intent)
        intent.action = Intent.ACTION_MAIN // aynı paylaşım yeniden işlenmesin
        val ctx: Context = applicationContext
        Thread {
            NativeBridge.readShare(ctx, copy)?.let { NativeBridge.deliverShare(it) }
        }.start()
        // Pusula'dan "Bilgisayara gönder": Köprü ekranı açılmadan gönderip geri çekil
        // (uygulama zaten çalışıyorsa; soğuk açılışta ekran açık kalır ki motor hazırlansın)
        if (copy.getBooleanExtra("dev.oalabs.kopru.OPEN", false) && NativeBridge.isDartReady()) {
            Toast.makeText(this, "Bilgisayara gönderiliyor", Toast.LENGTH_SHORT).show()
            finish()
        }
    }
}

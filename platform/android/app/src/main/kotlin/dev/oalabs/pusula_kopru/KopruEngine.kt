package dev.oalabs.pusula_kopru

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Uygulamanın tek Flutter motoru. Ekran (MainActivity) kapansa da arka plan hizmeti (KopruService)
 * çalıştıkça yaşar; böylece yerel sunucu, cihaz bulma ve dosya alma sürer.
 */
object KopruEngine {
    const val ID = "kopru"

    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        NativeBridge.attach(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }
}

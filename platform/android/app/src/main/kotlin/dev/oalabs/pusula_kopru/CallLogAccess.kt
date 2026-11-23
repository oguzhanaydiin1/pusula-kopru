package dev.oalabs.pusula_kopru

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog

/**
 * GEÇİCİ: arama kayıtlarını bilgisayardan görmek ve silmek için. İzinler yalnız KOPRU_CALLS=1 ile
 * derlenen ayrı APK'da bildirilir (standart APK'da yok, Play Protect ve Play kuralları yüzünden).
 */
object CallLogAccess {
    private val PERMS = arrayOf(Manifest.permission.READ_CALL_LOG, Manifest.permission.WRITE_CALL_LOG)

    /** Bu APK arama kaydı izinlerini bildiriyor mu (yalnız özel derlemede). */
    fun available(ctx: Context): Boolean = try {
        @Suppress("DEPRECATION")
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_PERMISSIONS)
        info.requestedPermissions?.contains(Manifest.permission.WRITE_CALL_LOG) == true
    } catch (_: Exception) {
        false
    }

    fun hasPermission(ctx: Context) = PERMS.all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun request(a: Activity?) {
        a?.requestPermissions(PERMS, 4791)
    }

    fun list(ctx: Context, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val proj = arrayOf(
            CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME,
            CallLog.Calls.DATE, CallLog.Calls.DURATION, CallLog.Calls.TYPE,
        )
        ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, proj, null, null, "${CallLog.Calls.DATE} DESC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                out.add(mapOf(
                    "id" to c.getLong(0),
                    "n" to (c.getString(1) ?: ""),
                    "name" to (c.getString(2) ?: ""),
                    "d" to c.getLong(3),
                    "dur" to c.getLong(4),
                    "type" to c.getInt(5),
                ))
            }
        }
        return out
    }

    /** [ids] boşsa ve [all] doğruysa hepsini siler. Dönüş: silinen kayıt sayısı. */
    fun delete(ctx: Context, ids: List<Long>, all: Boolean): Int {
        val cr = ctx.contentResolver
        if (all) return cr.delete(CallLog.Calls.CONTENT_URI, null, null)
        var n = 0
        for (chunk in ids.chunked(400)) {
            val where = "${CallLog.Calls._ID} IN (${chunk.joinToString(",") { "?" }})"
            n += cr.delete(CallLog.Calls.CONTENT_URI, where, chunk.map { it.toString() }.toTypedArray())
        }
        return n
    }
}

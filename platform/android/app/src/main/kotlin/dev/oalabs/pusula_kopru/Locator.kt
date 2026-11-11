package dev.oalabs.pusula_kopru

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper

/**
 * "Telefonu bul": bilgisayar istediğinde telefonun konumu. Google Play hizmetleri olmadan,
 * Android'in kendi konum servisiyle. Önce taze konum dener (en fazla 15 sn), olmazsa son bilineni verir.
 */
object Locator {
    fun hasPermission(c: Context): Boolean =
        c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            c.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun hasBackground(c: Context): Boolean =
        Build.VERSION.SDK_INT < 29 || c.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Önce ön plan izni; ardından (Android 10+) "Her zaman izin ver" için ikinci istek. */
    fun request(a: Activity?, background: Boolean) {
        a ?: return
        if (!hasPermission(a)) {
            a.requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), 44)
        } else if (background && Build.VERSION.SDK_INT >= 29 && !hasBackground(a)) {
            a.requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), 45)
        }
    }

    private fun toMap(l: Location, fresh: Boolean): Map<String, Any?> = mapOf(
        "lat" to l.latitude,
        "lon" to l.longitude,
        "acc" to (if (l.hasAccuracy()) l.accuracy.toDouble() else null),
        "time" to l.time,
        "provider" to l.provider,
        "fresh" to fresh,
    )

    @Suppress("MissingPermission")
    private fun lastKnown(lm: LocationManager): Location? {
        var best: Location? = null
        for (p in lm.getProviders(true)) {
            val l = try { lm.getLastKnownLocation(p) } catch (_: Exception) { null } ?: continue
            if (best == null || l.time > best.time) best = l
        }
        return best
    }

    @Suppress("MissingPermission", "DEPRECATION")
    fun locate(c: Context, done: (Map<String, Any?>?) -> Unit) {
        val lm = c.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val main = Handler(Looper.getMainLooper())
        var finished = false
        fun finish(l: Location?, fresh: Boolean) {
            if (finished) return
            finished = true
            val r = l ?: lastKnown(lm)
            done(r?.let { toMap(it, fresh && l != null) })
        }
        val provider = when {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }
        if (provider == null) {
            finish(null, false)
            return
        }
        main.postDelayed({ finish(null, false) }, 15_000)
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                lm.getCurrentLocation(provider, CancellationSignal(), c.mainExecutor) { l -> finish(l, true) }
            } else {
                // Eski Android'de dinleyicinin bütün yöntemleri yazılmalı (varsayılanları yok)
                lm.requestSingleUpdate(provider, object : LocationListener {
                    override fun onLocationChanged(l: Location) = finish(l, true)
                    override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) {}
                }, Looper.getMainLooper())
            }
        } catch (_: Exception) {
            finish(null, false)
        }
    }
}

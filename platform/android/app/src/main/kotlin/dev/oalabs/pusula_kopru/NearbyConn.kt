package dev.oalabs.pusula_kopru

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import org.json.JSONObject
import java.io.File

/**
 * İnternetsiz gönderme (telefondan telefona). Google'ın Nearby Connections altyapısı: cihazlar
 * birbirini Bluetooth ile bulur, aktarım için aralarında doğrudan Wi-Fi bağlantısı kurulur.
 * Bağlantı şifrelidir; iki ekranda aynı 4 haneli kod görünür.
 *
 * Dart'a giden olaylar ("bt" yöntemi, {e: ...}):
 *   found {id, name} · lost {id} · offer {id, name, count, total, digits} · digits {id, digits}
 *   connected {id} · rejected {id} · disconnected {id} · meta {id, pid, name, size}
 *   progress {id, pid, done, total} · file {id, pid, path, name} · failed {id, pid}
 */
object NearbyConn {
    private const val SERVICE = "dev.oalabs.pusula_kopru.yakin"
    private val main = Handler(Looper.getMainLooper())
    private var client: ConnectionsClient? = null
    private lateinit var app: Context
    var advertising = false
        private set
    var discovering = false
        private set
    private val incomingFiles = HashMap<Long, Payload>() // pid → dosya yükü (alan taraf)
    private val names = HashMap<Long, String>() // pid → dosya adı
    private val sizes = HashMap<Long, Long>()
    private val lastTick = HashMap<Long, Long>()
    private val outgoing = HashMap<String, MutableSet<Long>>() // uç → bekleyen gönderimler

    private fun emit(e: String, m: Map<String, Any?>) = NativeBridge.emit("bt", m + ("e" to e))

    private fun c(ctx: Context): ConnectionsClient {
        app = ctx.applicationContext
        return client ?: Nearby.getConnectionsClient(app).also { client = it }
    }

    fun available(ctx: Context): Boolean = try {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS
    } catch (_: Throwable) {
        false
    }

    private fun perms(): Array<String> = when {
        Build.VERSION.SDK_INT >= 33 -> arrayOf(
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.NEARBY_WIFI_DEVICES,
        )
        Build.VERSION.SDK_INT >= 31 -> arrayOf(
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.ACCESS_FINE_LOCATION,
        )
        else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    fun hasPermission(ctx: Context): Boolean = perms().all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun request(a: Activity?) {
        a ?: return
        a.requestPermissions(perms(), 4781)
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(id: String, info: ConnectionInfo) {
            if (info.isIncomingConnection) {
                // "ad|sayı|toplam"
                val parts = info.endpointName.split('|')
                emit("offer", mapOf(
                    "id" to id,
                    "name" to (parts.getOrNull(0) ?: "Telefon"),
                    "count" to (parts.getOrNull(1)?.toIntOrNull() ?: 0),
                    "total" to (parts.getOrNull(2)?.toLongOrNull() ?: 0L),
                    "digits" to info.authenticationDigits,
                ))
            } else {
                emit("digits", mapOf("id" to id, "digits" to info.authenticationDigits))
                client?.acceptConnection(id, payloads)
            }
        }

        override fun onConnectionResult(id: String, r: ConnectionResolution) {
            when (r.status.statusCode) {
                ConnectionsStatusCodes.STATUS_OK -> emit("connected", mapOf("id" to id))
                ConnectionsStatusCodes.STATUS_CONNECTION_REJECTED -> emit("rejected", mapOf("id" to id))
                else -> emit("disconnected", mapOf("id" to id))
            }
        }

        override fun onDisconnected(id: String) {
            outgoing.remove(id)
            emit("disconnected", mapOf("id" to id))
        }
    }

    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(id: String, p: Payload) {
            when (p.type) {
                Payload.Type.BYTES -> {
                    try {
                        val j = JSONObject(String(p.asBytes() ?: return, Charsets.UTF_8))
                        val pid = j.getLong("pid")
                        val name = j.optString("name", "dosya")
                        val size = j.optLong("size", 0)
                        names[pid] = name
                        sizes[pid] = size
                        emit("meta", mapOf("id" to id, "pid" to pid, "name" to name, "size" to size))
                    } catch (_: Exception) {}
                }
                Payload.Type.FILE -> incomingFiles[p.id] = p
                else -> {}
            }
        }

        override fun onPayloadTransferUpdate(id: String, u: PayloadTransferUpdate) {
            val pid = u.payloadId
            when (u.status) {
                PayloadTransferUpdate.Status.IN_PROGRESS -> {
                    val now = System.currentTimeMillis()
                    if (now - (lastTick[pid] ?: 0) >= 250) {
                        lastTick[pid] = now
                        emit("progress", mapOf("id" to id, "pid" to pid, "done" to u.bytesTransferred, "total" to u.totalBytes))
                    }
                }
                PayloadTransferUpdate.Status.SUCCESS -> {
                    lastTick.remove(pid)
                    val incoming = incomingFiles.remove(pid)
                    if (incoming != null) {
                        Thread { saveIncoming(id, pid, incoming) }.start()
                    } else if (outgoing[id]?.remove(pid) == true) {
                        emit("progress", mapOf("id" to id, "pid" to pid, "done" to u.totalBytes, "total" to u.totalBytes, "sent" to true))
                        if (outgoing[id]?.isEmpty() == true) {
                            outgoing.remove(id)
                            main.postDelayed({ client?.disconnectFromEndpoint(id) }, 1500)
                        }
                    }
                }
                PayloadTransferUpdate.Status.FAILURE, PayloadTransferUpdate.Status.CANCELED -> {
                    lastTick.remove(pid)
                    incomingFiles.remove(pid)
                    outgoing[id]?.remove(pid)
                    emit("failed", mapOf("id" to id, "pid" to pid))
                }
                else -> {}
            }
        }
    }

    private fun saveIncoming(id: String, pid: Long, p: Payload) {
        val name = names.remove(pid) ?: "dosya"
        sizes.remove(pid)
        try {
            val dir = File(app.cacheDir, "gelen").apply { mkdirs() }
            val out = File(dir, ".bt-$pid.part")
            val f = p.asFile()
            val uri: Uri? = if (Build.VERSION.SDK_INT >= 29) f?.asUri() else null
            if (uri != null) {
                app.contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
                try { app.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            } else {
                @Suppress("DEPRECATION")
                val jf = f?.asJavaFile() ?: throw IllegalStateException("dosya yok")
                if (!jf.renameTo(out)) {
                    jf.copyTo(out, overwrite = true)
                    jf.delete()
                }
            }
            emit("file", mapOf("id" to id, "pid" to pid, "path" to out.absolutePath, "name" to name))
        } catch (_: Exception) {
            emit("failed", mapOf("id" to id, "pid" to pid))
        }
    }

    fun advertise(ctx: Context, on: Boolean, name: String, done: (Boolean) -> Unit) {
        val cl = c(ctx)
        if (!on) {
            cl.stopAdvertising()
            advertising = false
            done(true)
            return
        }
        val opts = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_POINT_TO_POINT).build()
        cl.startAdvertising(name.take(40), SERVICE, lifecycle, opts)
            .addOnSuccessListener { advertising = true; done(true) }
            .addOnFailureListener { e ->
                // Zaten açıksa da başarı say
                advertising = (e as? com.google.android.gms.common.api.ApiException)?.statusCode == ConnectionsStatusCodes.STATUS_ALREADY_ADVERTISING
                done(advertising)
            }
    }

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(id: String, info: DiscoveredEndpointInfo) {
            if (info.serviceId != SERVICE) return
            emit("found", mapOf("id" to id, "name" to info.endpointName))
        }

        override fun onEndpointLost(id: String) = emit("lost", mapOf("id" to id))
    }

    fun discover(ctx: Context, on: Boolean, done: (Boolean) -> Unit) {
        val cl = c(ctx)
        if (!on) {
            cl.stopDiscovery()
            discovering = false
            done(true)
            return
        }
        val opts = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_POINT_TO_POINT).build()
        cl.startDiscovery(SERVICE, discovery, opts)
            .addOnSuccessListener { discovering = true; done(true) }
            .addOnFailureListener { e ->
                discovering = (e as? com.google.android.gms.common.api.ApiException)?.statusCode == ConnectionsStatusCodes.STATUS_ALREADY_DISCOVERING
                done(discovering)
            }
    }

    /** Gönderen: bağlantı iste. [label]: "ad|dosya sayısı|toplam bayt" */
    fun connect(ctx: Context, id: String, label: String, done: (Boolean) -> Unit) {
        val cl = c(ctx)
        // Aktarım hızlı olsun diye keşfi durdur (Wi-Fi'ye geçişi kolaylaştırır)
        cl.stopDiscovery()
        discovering = false
        cl.requestConnection(label.take(120), id, lifecycle)
            .addOnSuccessListener { done(true) }
            .addOnFailureListener { done(false) }
    }

    fun answer(ctx: Context, id: String, accept: Boolean) {
        val cl = c(ctx)
        if (accept) cl.acceptConnection(id, payloads) else cl.rejectConnection(id)
    }

    /** Gönderen: dosyaları sırayla yolla. Dönüş: her dosyanın yük kimliği (pid). */
    fun send(ctx: Context, id: String, files: List<Map<String, Any?>>): List<Long> {
        val cl = c(ctx)
        val out = ArrayList<Long>()
        val set = outgoing.getOrPut(id) { HashSet() }
        for (f in files) {
            val path = f["path"] as? String ?: continue
            val file = File(path)
            if (!file.isFile) continue
            val p = try { Payload.fromFile(file) } catch (_: Exception) { continue }
            val meta = JSONObject()
                .put("pid", p.id)
                .put("name", f["name"] as? String ?: file.name)
                .put("size", file.length())
            cl.sendPayload(id, Payload.fromBytes(meta.toString().toByteArray(Charsets.UTF_8)))
            cl.sendPayload(id, p)
            set.add(p.id)
            out.add(p.id)
        }
        return out
    }

    fun cancel(ctx: Context, pid: Long) {
        c(ctx).cancelPayload(pid)
    }

    fun disconnect(ctx: Context, id: String) {
        outgoing.remove(id)
        c(ctx).disconnectFromEndpoint(id)
    }

    fun stopAll(ctx: Context) {
        val cl = c(ctx)
        cl.stopAdvertising()
        cl.stopDiscovery()
        cl.stopAllEndpoints()
        advertising = false
        discovering = false
        outgoing.clear()
    }
}

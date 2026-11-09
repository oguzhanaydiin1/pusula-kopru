package dev.oalabs.pusula_kopru

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Pusula Köprü'nün Android tarafı ("kopru/native" kanalı):
 * paylaş menüsünden gelenler, İndirilenler'e kaydetme, telefonu çaldırma, pil, cihaz adı,
 * yerel ağda cihaz bulma için çoklu yayın kilidi.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var dartReady = false
    private var pendingShare: Map<String, Any?>? = null
    private var ringtone: Ringtone? = null
    private var savedAlarmVolume = -1
    private var multicastLock: WifiManager.MulticastLock? = null
    private val main = Handler(Looper.getMainLooper())
    private val stopRingTask = Runnable { stopRing() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kopru/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialShare" -> {
                    dartReady = true
                    result.success(pendingShare)
                    pendingShare = null
                }
                "deviceName" -> result.success(deviceName())
                "battery" -> result.success(battery())
                "multicast" -> {
                    acquireMulticast()
                    result.success(true)
                }
                "ring" -> {
                    ring()
                    result.success(true)
                }
                "stopRing" -> {
                    stopRing()
                    result.success(true)
                }
                "saveToDownloads" -> {
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: File(path).name
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    Thread {
                        try {
                            val uri = saveToDownloads(File(path), name, mime)
                            main.post { result.success(uri) }
                        } catch (e: Exception) {
                            main.post { result.error("save", e.message, null) }
                        }
                    }.start()
                }
                "openUri" -> result.success(openUri(call.argument<String>("uri") ?: "", call.argument<String>("mime")))
                "openDownloads" -> result.success(openDownloads())
                "openInPusula" -> result.success(openInPusula(call.argument<String>("url") ?: ""))
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        stopRing()
        try { multicastLock?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    // ---- Paylaş menüsü ----

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val copy = Intent(intent)
        // Aynı paylaşım (ör. ekran döndüğünde) yeniden işlenmesin
        intent.action = Intent.ACTION_MAIN
        Thread {
            val payload = readShare(copy)
            main.post {
                if (payload == null) return@post
                if (dartReady && channel != null) {
                    channel?.invokeMethod("shared", payload)
                } else {
                    pendingShare = payload
                }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun readShare(intent: Intent): Map<String, Any?>? {
        val uris = ArrayList<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        if (uris.isEmpty()) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
            return mapOf("text" to text)
        }
        val dir = File(cacheDir, "paylasilan")
        dir.mkdirs()
        val paths = ArrayList<String>()
        for (u in uris) {
            try {
                val name = (displayName(u) ?: "dosya").replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val out = uniqueFile(dir, name)
                contentResolver.openInputStream(u)?.use { input ->
                    out.outputStream().use { output -> input.copyTo(output, 256 * 1024) }
                }
                paths.add(out.absolutePath)
            } catch (_: Exception) {
            }
        }
        if (paths.isEmpty()) return null
        return mapOf("files" to paths)
    }

    private fun uniqueFile(dir: File, name: String): File {
        var out = File(dir, name)
        var n = 1
        while (out.exists()) {
            val dot = name.lastIndexOf('.')
            out = if (dot > 0) File(dir, name.substring(0, dot) + " ($n)" + name.substring(dot)) else File(dir, "$name ($n)")
            n++
        }
        return out
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (i >= 0) return c.getString(i)
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment
    }

    // ---- İndirilenler ----

    private fun saveToDownloads(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Pusula Köprü")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("İndirilenler'e yazılamadı")
            contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { it.copyTo(out, 256 * 1024) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            src.delete()
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Pusula Köprü")
        dir.mkdirs()
        val out = uniqueFile(dir, name)
        src.copyTo(out)
        src.delete()
        return out.absolutePath
    }

    private fun openUri(uri: String, mime: String?): Boolean {
        if (!uri.startsWith("content://")) return openDownloads()
        return try {
            val u = Uri.parse(uri)
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(u, mime ?: contentResolver.getType(u) ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(i, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openDownloads(): Boolean {
        return try {
            startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openInPusula(url: String): Boolean {
        val uri = Uri.parse(url)
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("dev.oalabs.oa_tarayici").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return true
        } catch (_: ActivityNotFoundException) {
        } catch (_: Exception) {
        }
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ---- Cihaz ----

    private fun deviceName(): String {
        val n = try { Settings.Global.getString(contentResolver, "device_name") } catch (_: Exception) { null }
        if (!n.isNullOrBlank()) return n
        val model = Build.MODEL ?: "Android"
        val maker = Build.MANUFACTURER ?: ""
        return if (maker.isNotEmpty() && !model.lowercase().startsWith(maker.lowercase()))
            maker.replaceFirstChar { it.uppercase() } + " " + model
        else model
    }

    private fun battery(): Map<String, Any> {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val status = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to level, "charging" to charging)
    }

    private fun acquireMulticast() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("pusula-kopru").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    // ---- Telefonu çaldır: sessizdeyken de alarm sesiyle çalar ----

    private fun ring() {
        stopRing()
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (_: Exception) {
        }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        ringtone = RingtoneManager.getRingtone(applicationContext, uri)?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            play()
        }
        try {
            @Suppress("DEPRECATION")
            val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            val pattern = longArrayOf(0, 600, 400, 600, 400, 600, 400, 600)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, -1)
            }
        } catch (_: Exception) {
        }
        main.postDelayed(stopRingTask, 30_000) // en fazla 30 saniye
    }

    private fun stopRing() {
        main.removeCallbacks(stopRingTask)
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
        if (savedAlarmVolume >= 0) {
            try {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
            } catch (_: Exception) {
            }
            savedAlarmVolume = -1
        }
        try {
            @Suppress("DEPRECATION")
            (getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).cancel()
        } catch (_: Exception) {
        }
    }
}

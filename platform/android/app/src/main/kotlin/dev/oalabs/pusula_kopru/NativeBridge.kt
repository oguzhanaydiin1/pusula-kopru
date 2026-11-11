package dev.oalabs.pusula_kopru

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
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
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.lang.ref.WeakReference

/**
 * "kopru/native" kanalı. Motorla birlikte yaşar; ekran (MainActivity) açık olmasa da çalışır.
 * Ekran gerektiren işler (izin isteme) yalnız ekran açıkken yapılır.
 */
object NativeBridge {
    private lateinit var app: Context
    private var channel: MethodChannel? = null
    private var dartReady = false
    private var pendingShare: Map<String, Any?>? = null
    private var activityRef: WeakReference<Activity>? = null
    private var ringtone: Ringtone? = null
    private var savedAlarmVolume = -1
    private var multicastLock: WifiManager.MulticastLock? = null
    private val main = Handler(Looper.getMainLooper())
    private val stopRingTask = Runnable { stopRing() }
    private var notifSeq = 100
    private const val PREFS = "kopru_native"
    const val RING_NOTIF = 4722

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        KopruService.channels(app)
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "kopru/native")
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
                "multicast" -> { acquireMulticast(); result.success(true) }
                "ring" -> { ring(call.argument<String>("from") ?: "Bilgisayar"); result.success(true) }
                "stopRing" -> { stopRing(); result.success(true) }
                "saveToDownloads" -> {
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: File(path).name
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    val sub = call.argument<String>("sub") ?: ""
                    Thread {
                        try {
                            val uri = saveToDownloads(File(path), name, mime, sub)
                            main.post { result.success(uri) }
                        } catch (e: Exception) {
                            main.post { result.error("save", e.message, null) }
                        }
                    }.start()
                }
                "openUri" -> result.success(openUri(call.argument<String>("uri") ?: "", call.argument<String>("mime")))
                "openDownloads" -> result.success(openDownloads())
                "openInPusula" -> result.success(openInPusula(call.argument<String>("url") ?: ""))
                "setBackground" -> {
                    val on = call.argument<Boolean>("on") == true
                    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("background", on).apply()
                    if (on) KopruService.start(app) else KopruService.stop(app)
                    result.success(true)
                }
                "notify" -> {
                    notify(
                        call.argument<String>("title") ?: "Pusula Köprü",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("uri"),
                        call.argument<String>("mime"),
                        call.argument<String>("url"),
                    )
                    result.success(true)
                }
                "requestNotifications" -> { requestNotificationPermission(); result.success(true) }
                "latestScreenshot" -> {
                    if (!hasImagePermission()) {
                        requestImagePermission()
                        result.success(mapOf("permission" to true))
                    } else {
                        Thread {
                            val r = try { latestScreenshot() } catch (e: Exception) { null }
                            main.post { result.success(r) }
                        }.start()
                    }
                }
                "isForeground" -> result.success(activityRef?.get() != null)
                "notificationAccess" -> result.success(NotifListener.hasAccess(app))
                "mediaPermission" -> result.success(MediaAccess.hasPermission(app))
                "requestMedia" -> { MediaAccess.request(activityRef?.get()); result.success(activityRef?.get() != null) }
                "listMedia" -> {
                    val kind = call.argument<String>("kind") ?: "img"
                    val offset = call.argument<Int>("offset") ?: 0
                    val limit = call.argument<Int>("limit") ?: 60
                    bg(result) { if (MediaAccess.hasPermission(app)) MediaAccess.list(app, kind, offset, limit) else null }
                }
                "newMedia" -> {
                    val since = (call.argument<Number>("since") ?: 0).toLong()
                    val limit = call.argument<Int>("limit") ?: 50
                    bg(result) { if (MediaAccess.hasPermission(app)) MediaAccess.newSince(app, since, limit) else null }
                }
                "thumb" -> {
                    val id = call.argument<String>("id") ?: ""
                    val px = call.argument<Int>("px") ?: 200
                    bg(result) { MediaAccess.thumb(app, id, px) }
                }
                "copyMedia" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: "dosya"
                    bg(result) { MediaAccess.copy(app, id, name) }
                }
                "locationPermission" -> result.success(Locator.hasPermission(app))
                "requestLocation" -> {
                    Locator.request(activityRef?.get(), call.argument<Boolean>("background") == true)
                    result.success(true)
                }
                "locate" -> {
                    if (!Locator.hasPermission(app)) {
                        result.success(mapOf("permission" to false))
                    } else {
                        Locator.locate(app) { loc -> main.post { result.success(loc) } }
                    }
                }
                "setLang" -> {
                    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("lang", call.argument<String>("lang") ?: "tr").apply()
                    KopruService.channels(app)
                    result.success(true)
                }
                "captureVolume" -> { captureVolume = call.argument<Boolean>("on") == true; result.success(true) }
                "mirrorAvailable" -> result.success(
                    try {
                        app.packageManager.getServiceInfo(android.content.ComponentName(app, NotifListener::class.java), 0)
                        true
                    } catch (_: Exception) {
                        false
                    }
                )
                "openNotificationAccess" -> {
                    try {
                        app.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (_: Exception) {
                    }
                    result.success(true)
                }
                "setMirror" -> {
                    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("mirror", call.argument<Boolean>("on") == true).apply()
                    result.success(true)
                }
                "replyNotification" -> result.success(
                    NotifListener.reply(app, call.argument<String>("key") ?: "", call.argument<String>("text") ?: "")
                )
                else -> result.notImplemented()
            }
        }
    }

    fun isDartReady(): Boolean = dartReady

    /** Uygulama dili İngilizce mi (Dart tarafı bildirir; ilk açılışta cihaz dili) */
    fun en(c: Context): Boolean {
        val l = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("lang", null)
        return if (l != null) l == "en" else !java.util.Locale.getDefault().language.equals("tr", ignoreCase = true)
    }

    fun t(c: Context, tr: String, en: String) = if (en(c)) en else tr

    /** Sunum kumandasında ses tuşları slayt geçsin */
    var captureVolume = false

    private fun bg(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            val r = try { work() } catch (_: Exception) { null }
            main.post { result.success(r) }
        }.start()
    }

    fun setActivity(a: Activity?) {
        activityRef = if (a == null) null else WeakReference(a)
    }

    fun backgroundEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("background", false)

    // ---- Paylaş menüsü ----

    fun deliverShare(payload: Map<String, Any?>) {
        main.post {
            if (dartReady && channel != null) channel?.invokeMethod("shared", payload) else pendingShare = payload
        }
    }

    @Suppress("DEPRECATION")
    fun readShare(context: Context, intent: Intent): Map<String, Any?>? {
        val uris = ArrayList<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        val open = intent.getBooleanExtra("dev.oalabs.kopru.OPEN", false)
        if (uris.isEmpty()) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
            return mapOf("text" to text, "open" to open)
        }
        val dir = File(context.cacheDir, "paylasilan")
        dir.mkdirs()
        val paths = ArrayList<String>()
        for (u in uris) {
            try {
                val name = (displayName(context, u) ?: "dosya").replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val out = uniqueFile(dir, name)
                context.contentResolver.openInputStream(u)?.use { input ->
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

    private fun displayName(context: Context, uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
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

    private fun saveToDownloads(src: File, name: String, mime: String, sub: String): String {
        val cleanSub = sub.split('/').map { it.replace(Regex("[\\\\:*?\"<>|]"), "_").trim() }
            .filter { it.isNotEmpty() && it != "." && it != ".." }.joinToString("/")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rel = Environment.DIRECTORY_DOWNLOADS + "/Pusula Köprü" + (if (cleanSub.isEmpty()) "" else "/$cleanSub")
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = app.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("İndirilenler'e yazılamadı")
            app.contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { it.copyTo(out, 256 * 1024) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            app.contentResolver.update(uri, values, null, null)
            src.delete()
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        var dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Pusula Köprü")
        if (cleanSub.isNotEmpty()) dir = File(dir, cleanSub)
        dir.mkdirs()
        val out = uniqueFile(dir, name)
        src.copyTo(out)
        src.delete()
        return out.absolutePath
    }

    fun openUri(uri: String, mime: String?): Boolean {
        if (!uri.startsWith("content://")) return openDownloads()
        return try {
            val u = Uri.parse(uri)
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(u, mime ?: app.contentResolver.getType(u) ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            app.startActivity(Intent.createChooser(i, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    fun openDownloads(): Boolean {
        return try {
            app.startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    fun openInPusula(url: String): Boolean {
        val uri = Uri.parse(url)
        try {
            app.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("dev.oalabs.oa_tarayici").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return true
        } catch (_: ActivityNotFoundException) {
        } catch (_: Exception) {
        }
        return try {
            app.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ---- Bildirimler ----

    private fun canNotify(): Boolean =
        Build.VERSION.SDK_INT < 33 || app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || canNotify()) return
        val a = activityRef?.get() ?: return
        a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
    }

    /** Dokununca: dosyayı açar (uri), bağlantıyı Pusula'da açar (url) ya da uygulamayı açar. */
    private fun notify(title: String, text: String, uri: String?, mime: String?, url: String?) {
        if (!canNotify()) return
        val id = notifSeq++
        val tap = Intent(app, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (uri != null) { putExtra("kopru_open_uri", uri); putExtra("kopru_mime", mime) }
            if (url != null) putExtra("kopru_open_url", url)
        }
        val pi = PendingIntent.getActivity(app, id, tap, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(app, KopruService.CH_INCOMING) else @Suppress("DEPRECATION") Notification.Builder(app)
        val n = b.setSmallIcon(R.drawable.ic_stat_kopru)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id, n)
    }

    // ---- Son ekran görüntüsü ----

    private fun imagePermission(): String =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun hasImagePermission(): Boolean =
        app.checkSelfPermission(imagePermission()) == PackageManager.PERMISSION_GRANTED ||
            (Build.VERSION.SDK_INT >= 34 && app.checkSelfPermission("android.permission.READ_MEDIA_VISUAL_USER_SELECTED") == PackageManager.PERMISSION_GRANTED)

    private fun requestImagePermission() {
        val a = activityRef?.get() ?: return
        a.requestPermissions(arrayOf(imagePermission()), 42)
    }

    @Suppress("DEPRECATION")
    private fun latestScreenshot(): Map<String, Any?>? {
        val col = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val proj = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_ADDED)
        val (sel, args) = if (Build.VERSION.SDK_INT >= 29) {
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?" to arrayOf("%Screenshot%")
        } else {
            "${MediaStore.Images.Media.DATA} LIKE ?" to arrayOf("%Screenshot%")
        }
        app.contentResolver.query(col, proj, sel, args, "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { c ->
            if (!c.moveToFirst()) return mapOf("none" to true)
            val id = c.getLong(0)
            val name = c.getString(1) ?: "ekran.png"
            val uri = ContentUris.withAppendedId(col, id)
            val dir = File(app.cacheDir, "paylasilan")
            dir.mkdirs()
            val out = uniqueFile(dir, name)
            app.contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
            return mapOf("path" to out.absolutePath, "added" to c.getLong(2))
        }
        return mapOf("none" to true)
    }

    // ---- Cihaz ----

    private fun deviceName(): String {
        val n = try { Settings.Global.getString(app.contentResolver, "device_name") } catch (_: Exception) { null }
        if (!n.isNullOrBlank()) return n
        val model = Build.MODEL ?: "Android"
        val maker = Build.MANUFACTURER ?: ""
        return if (maker.isNotEmpty() && !model.lowercase().startsWith(maker.lowercase()))
            maker.replaceFirstChar { it.uppercase() } + " " + model
        else model
    }

    private fun battery(): Map<String, Any> {
        val bm = app.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val status = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("level" to level, "charging" to charging)
    }

    private fun acquireMulticast() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("pusula-kopru").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    // ---- Telefonu çaldır: sessizdeyken de alarm sesiyle çalar ----

    private fun ring(from: String) {
        stopRing(notifyDart = false) // önceki çalma varsa sessizce kapat
        try {
            val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (_: Exception) {
        }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        ringtone = (RingtoneManager.getRingtone(app, uri)
            ?: RingtoneManager.getRingtone(app, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)))?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            play()
        }
        try {
            @Suppress("DEPRECATION")
            val v = app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            val pattern = longArrayOf(0, 600, 400, 600, 400, 600, 400, 600)
            // 0: deseni durdurulana kadar tekrarla
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            else @Suppress("DEPRECATION") v.vibrate(pattern, 0)
        } catch (_: Exception) {
        }
        // Ekran kapalıyken de durdurulabilsin: "Durdur" düğmeli bildirim
        if (canNotify()) {
            val stop = PendingIntent.getService(
                app, 1, Intent(app, KopruService::class.java).setAction(KopruService.ACTION_STOP_RING),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(app, KopruService.CH_RING) else @Suppress("DEPRECATION") Notification.Builder(app)
            @Suppress("DEPRECATION")
            val n = b.setSmallIcon(R.drawable.ic_stat_kopru)
                .setContentTitle(t(app, "Telefonun burada", "Your phone is here"))
                .setContentText(t(app, "$from seni arıyor", "$from is looking for you"))
                .setContentIntent(stop)
                .addAction(Notification.Action.Builder(null, t(app, "Durdur", "Stop"), stop).build())
                .setDeleteIntent(stop)
                .setCategory(Notification.CATEGORY_ALARM)
                .setPriority(Notification.PRIORITY_MAX)
                .build()
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(RING_NOTIF, n)
        }
        main.postDelayed(stopRingTask, 30_000) // en fazla 30 saniye
    }

    /** [notifyDart]: ekrandaki "Telefonun burada" penceresi de kapansın (Durdur'a basılınca, süre dolunca). */
    fun stopRing(notifyDart: Boolean = true) {
        val wasRinging = ringtone != null
        main.removeCallbacks(stopRingTask)
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
        if (savedAlarmVolume >= 0) {
            try {
                val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
            } catch (_: Exception) {
            }
            savedAlarmVolume = -1
        }
        try {
            @Suppress("DEPRECATION")
            (app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).cancel()
        } catch (_: Exception) {
        }
        try {
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(RING_NOTIF)
        } catch (_: Exception) {
        }
        if (notifyDart && wasRinging) main.post { channel?.invokeMethod("ringStopped", null) }
    }

    /** Bildirim aynası ve diğer olaylar için Dart'a ileti. */
    fun emit(method: String, args: Any?) {
        main.post { channel?.invokeMethod(method, args) }
    }
}

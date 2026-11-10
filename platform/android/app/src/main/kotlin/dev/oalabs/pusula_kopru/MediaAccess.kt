package dev.oalabs.pusula_kopru

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Telefonun fotoğraf, video ve İndirilenler'i: bilgisayardan göz atma ve fotoğraf yedekleme için.
 * Kimlikler "tür:numara" biçimindedir (ör. "img:1234").
 */
object MediaAccess {
    private fun collection(kind: String): Uri? = when (kind) {
        "img" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        "vid" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        "dl" -> if (Build.VERSION.SDK_INT >= 29) MediaStore.Downloads.EXTERNAL_CONTENT_URI else null
        else -> null
    }

    private fun perms(): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)

    fun hasPermission(c: Context): Boolean = perms().all { c.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun request(a: Activity?) {
        a?.requestPermissions(perms(), 43)
    }

    fun uriOf(id: String): Uri? {
        val p = id.split(':')
        if (p.size != 2) return null
        val col = collection(p[0]) ?: return null
        val n = p[1].toLongOrNull() ?: return null
        return ContentUris.withAppendedId(col, n)
    }

    /** Sayfa sayfa liste (yeniden eskiye). */
    fun list(c: Context, kind: String, offset: Int, limit: Int): List<Map<String, Any?>> {
        val col = collection(kind) ?: return emptyList()
        val proj = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.MIME_TYPE
        )
        val out = ArrayList<Map<String, Any?>>()
        c.contentResolver.query(col, proj, null, null, "${MediaStore.MediaColumns.DATE_ADDED} DESC")?.use { cur ->
            if (!cur.moveToPosition(offset)) return out
            do {
                out.add(row(kind, cur.getLong(0), cur.getString(1), cur.getLong(2), cur.getLong(3), cur.getString(4), null))
            } while (out.size < limit && cur.moveToNext())
        }
        return out
    }

    /** Yedekleme: [since] (saniye) sonrasında eklenen fotoğraf ve videolar, eskiden yeniye. */
    fun newSince(c: Context, since: Long, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (kind in listOf("img", "vid")) {
            val col = collection(kind) ?: continue
            val bucket = if (Build.VERSION.SDK_INT >= 29) MediaStore.MediaColumns.RELATIVE_PATH else MediaStore.MediaColumns.DATA
            val proj = arrayOf(
                MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.MIME_TYPE, bucket
            )
            c.contentResolver.query(
                col, proj, "${MediaStore.MediaColumns.DATE_ADDED} > ?", arrayOf(since.toString()),
                "${MediaStore.MediaColumns.DATE_ADDED} ASC"
            )?.use { cur ->
                while (cur.moveToNext() && out.size < limit * 2) {
                    val path = cur.getString(5) ?: ""
                    // Uygulamanın kendi indirdikleri (Pusula Köprü klasörü) yedeklenmesin
                    if (path.contains("Pusula Köprü")) continue
                    out.add(row(kind, cur.getLong(0), cur.getString(1), cur.getLong(2), cur.getLong(3), cur.getString(4), path))
                }
            }
        }
        out.sortBy { it["date"] as Long }
        return out.take(limit)
    }

    private fun row(kind: String, id: Long, name: String?, size: Long, added: Long, mime: String?, path: String?) = mapOf(
        "id" to "$kind:$id",
        "name" to (name ?: "dosya"),
        "size" to size,
        "date" to added * 1000,
        "mime" to mime,
        "path" to path,
    )

    /** Küçük resim (JPEG). */
    @Suppress("DEPRECATION")
    fun thumb(c: Context, id: String, px: Int): ByteArray? {
        val uri = uriOf(id) ?: return null
        val bmp: Bitmap? = try {
            if (Build.VERSION.SDK_INT >= 29) {
                c.contentResolver.loadThumbnail(uri, Size(px, px), null)
            } else {
                val n = id.substringAfter(':').toLong()
                if (id.startsWith("vid:")) MediaStore.Video.Thumbnails.getThumbnail(c.contentResolver, n, MediaStore.Video.Thumbnails.MINI_KIND, null)
                else MediaStore.Images.Thumbnails.getThumbnail(c.contentResolver, n, MediaStore.Images.Thumbnails.MINI_KIND, null)
            }
        } catch (_: Exception) {
            null
        }
        bmp ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 72, out)
        return out.toByteArray()
    }

    /** Göndermek için uygulamanın geçici klasörüne kopyalar. */
    fun copy(c: Context, id: String, name: String): String? {
        val uri = uriOf(id) ?: return null
        val dir = File(c.cacheDir, "gonderilecek")
        dir.mkdirs()
        val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val f = File(dir, "${id.replace(':', '_')}_$safe")
        return try {
            c.contentResolver.openInputStream(uri)?.use { i -> f.outputStream().use { i.copyTo(it, 256 * 1024) } }
            f.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}

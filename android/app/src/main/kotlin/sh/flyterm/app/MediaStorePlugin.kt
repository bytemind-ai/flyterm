package sh.flyterm.app

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Publishes an already-written private file into the user-visible public
 * Downloads collection (`Download/FlyTerm/…`), so exports and SFTP downloads
 * show up in the system Files app instead of the hidden app sandbox.
 *
 * API 29+ : MediaStore.Downloads (no storage permission required).
 * API 24-28: legacy write into the public Downloads dir; the caller must have
 *            been granted WRITE_EXTERNAL_STORAGE first (Dart requests it).
 */
object MediaStorePlugin {
    const val CHANNEL = "sh.flyterm.app/media_store"
    private const val SUBDIR = "FlyTerm"

    fun handle(context: Context, method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)
            "publishToDownloads" -> {
                try {
                    val sourcePath = args?.get("sourcePath") as? String
                    val fileName = args?.get("fileName") as? String
                    val mimeType = args?.get("mimeType") as? String ?: "application/octet-stream"
                    if (sourcePath == null || fileName == null) {
                        result.error("BAD_ARGS", "sourcePath and fileName are required", null)
                        return
                    }
                    val source = File(sourcePath)
                    if (!source.exists()) {
                        result.error("NO_SOURCE", "source file does not exist: $sourcePath", null)
                        return
                    }
                    val published = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        publishViaMediaStore(context, source, fileName, mimeType)
                    } else {
                        publishViaLegacy(source, fileName)
                    }
                    result.success(published)
                } catch (e: SecurityException) {
                    result.error("PERMISSION_REQUIRED", e.message, null)
                } catch (e: Exception) {
                    result.error("PUBLISH_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun publishViaMediaStore(
        context: Context,
        source: File,
        fileName: String,
        mimeType: String,
    ): Map<String, Any?> {
        val resolver = context.contentResolver
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore.insert returned null")
        resolver.openOutputStream(uri).use { out ->
            if (out == null) throw IllegalStateException("openOutputStream returned null")
            source.inputStream().use { it.copyTo(out) }
        }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return mapOf(
            "uri" to uri.toString(),
            "displayName" to fileName,
            "publicPath" to "$relativePath/$fileName",
        )
    }

    private fun publishViaLegacy(source: File, fileName: String): Map<String, Any?> {
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val targetDir = File(downloads, SUBDIR)
        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw IllegalStateException("cannot create ${targetDir.absolutePath}")
        }
        val target = File(targetDir, fileName)
        source.inputStream().use { input ->
            target.outputStream().use { input.copyTo(it) }
        }
        return mapOf(
            "uri" to null,
            "displayName" to fileName,
            "publicPath" to target.absolutePath,
        )
    }
}

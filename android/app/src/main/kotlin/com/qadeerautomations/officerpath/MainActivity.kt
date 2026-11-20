package com.qadeerautomations.officerpath

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val DOWNLOADS_CHANNEL =
            "com.qadeerautomations.officerpath/downloads"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOADS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method == "saveToDownloads") {
                val fileName = call.argument<String>("fileName")
                val bytes = call.argument<ByteArray>("bytes")
                if (fileName.isNullOrBlank() || bytes == null) {
                    result.error(
                        "INVALID_ARGS",
                        "saveToDownloads needs a fileName and bytes",
                        null,
                    )
                    return@setMethodCallHandler
                }
                try {
                    val saved = saveToDownloads(fileName, bytes)
                    if (saved != null) {
                        result.success(saved)
                    } else {
                        result.error(
                            "SAVE_FAILED",
                            "Could not save $fileName to Downloads",
                            null,
                        )
                    }
                } catch (e: Exception) {
                    result.error("SAVE_FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    /// Saves [bytes] as [fileName] in the phone's public Downloads
    /// folder and returns where it landed (a content URI on Android
    /// 10+, a file path below that), or null on failure.
    ///
    /// Android 10+ (API 29+): MediaStore.Downloads — no permission
    /// needed for the app's own files. The entry is IS_PENDING while
    /// the bytes are written, then published, so the file only appears
    /// in Downloads once it is complete.
    ///
    /// Android 9 and below: MediaStore.Downloads does not exist, so
    /// the file is written directly to the public Downloads directory
    /// (needs WRITE_EXTERNAL_STORAGE, declared maxSdkVersion 28 in
    /// the manifest).
    private fun saveToDownloads(fileName: String, bytes: ByteArray): String? {
        val mimeType = when (fileName.substringAfterLast('.', "").lowercase()) {
            "pdf" -> "application/pdf"
            "png" -> "image/png"
            else -> "application/octet-stream"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS,
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: return null
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    out.write(bytes)
                    out.flush()
                } ?: run {
                    resolver.delete(uri, null, null)
                    return null
                }
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            // Publish: clear IS_PENDING so the file shows in Downloads.
            val published = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, published, null, null)
            // VERIFY the file really exists before reporting success:
            // a published MediaStore row that cannot be opened again
            // (e.g. storage vanished mid-write) must not be reported
            // as a saved download.
            val exists = try {
                resolver.query(
                    uri,
                    arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                    null, null, null,
                )?.use { cursor -> cursor.moveToFirst() } ?: false
            } catch (e: Exception) {
                false
            }
            if (!exists) {
                resolver.delete(uri, null, null)
                return null
            }
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            if (!downloadsDir.exists() && !downloadsDir.mkdirs()) {
                return null
            }
            val file = File(downloadsDir, fileName)
            FileOutputStream(file).use { out ->
                out.write(bytes)
                out.flush()
            }
            // VERIFY the file really landed (exists, right size)
            // before reporting success — same contract as the
            // MediaStore path above.
            if (!file.exists() || file.length() != bytes.size.toLong()) {
                return null
            }
            return file.absolutePath
        }
    }
}

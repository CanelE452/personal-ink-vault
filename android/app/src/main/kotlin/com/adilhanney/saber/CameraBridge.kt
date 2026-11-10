package io.github.canele452.personalinkvault

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.Executors

class CameraBridge(private val activity: Activity) {
    interface Completion {
        fun success(value: Map<String, Any>?)
        fun error(code: String, message: String)
    }

    private data class Capture(val completion: Completion, val file: File, val uri: Uri)
    private val files = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: Capture? = null
    private var disposed = false

    fun capabilities(): Map<String, Any> {
        val available = !disposed && Intent(MediaStore.ACTION_IMAGE_CAPTURE).resolveActivity(activity.packageManager) != null
        return if (available) mapOf("available" to true)
        else mapOf("available" to false, "reason" to "카메라 앱을 사용할 수 없습니다.")
    }

    fun capture(completion: Completion) {
        if (disposed) {
            completion.error("interrupted", "촬영 화면이 종료되었습니다.")
            return
        }
        if (pending != null) {
            completion.error("busy", "사진을 이미 촬영하고 있습니다.")
            return
        }
        if (capabilities()["available"] != true) {
            completion.error("unavailable", "카메라 앱을 사용할 수 없습니다.")
            return
        }
        var photo: File? = null
        try {
            val directory = File(activity.filesDir, "photo-imports")
            if (!directory.isDirectory && !directory.mkdirs()) throw java.io.IOException("Cannot create photo directory")
            photo = File.createTempFile("photo-", ".jpg", directory)
            val uri = FileProvider.getUriForFile(activity, activity.packageName + ".camera", photo)
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                clipData = ClipData.newRawUri("Photo capture", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            pending = Capture(completion, photo, uri)
            activity.startActivityForResult(intent, REQUEST_CAPTURE)
        } catch (_: Exception) {
            pending?.let { revoke(it) }
            pending = null
            photo?.delete()
            completion.error("capture_failed", "카메라 앱을 열지 못했습니다.")
        }
    }

    @Suppress("UNUSED_PARAMETER")
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAPTURE) return false
        val capture = pending ?: return true
        revoke(capture)
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            capture.file.delete()
            capture.completion.success(null)
            return true
        }
        files.execute {
            try {
                val extension = validatePhoto(capture.file)
                val destination = if (extension == "jpg") capture.file else File(capture.file.parentFile, capture.file.nameWithoutExtension + "." + extension)
                if (destination != capture.file && !capture.file.renameTo(destination)) throw java.io.IOException("Photo rename failed")
                main.post {
                    if (disposed || pending !== capture) {
                        destination.delete()
                    } else {
                        pending = null
                        capture.completion.success(mapOf("path" to destination.absolutePath, "fileName" to destination.name))
                    }
                }
            } catch (_: Exception) {
                main.post {
                    capture.file.delete()
                    if (!disposed && pending === capture) {
                        pending = null
                        capture.completion.error("invalid_image", "촬영한 사진을 완전히 읽지 못했습니다.")
                    }
                }
            }
        }
        return true
    }

    private fun validatePhoto(file: File): String {
        if (!file.isFile || file.length() <= 0 || file.length() > MAX_BYTES) throw java.io.IOException("Invalid photo size")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS) {
            throw java.io.IOException("Invalid photo dimensions")
        }
        val extension = when (bounds.outMimeType) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> throw java.io.IOException("Unsupported photo format")
        }
        var sample = 1
        while (bounds.outWidth / sample > 1024 || bounds.outHeight / sample > 1024) sample *= 2
        val decoded = try {
            BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (_: OutOfMemoryError) {
            throw java.io.IOException("Photo decoding memory limit")
        } ?: throw java.io.IOException("Invalid photo pixels")
        decoded.recycle()
        return extension
    }

    private fun revoke(capture: Capture) {
        try {
            activity.revokeUriPermission(capture.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (_: SecurityException) { }
    }

    fun dispose() {
        disposed = true
        val capture = pending
        pending = null
        if (capture != null) {
            revoke(capture)
            capture.file.delete()
            capture.completion.error("interrupted", "사진 촬영이 중단되었습니다. 다시 촬영해 주세요.")
        }
        files.shutdownNow()
    }

    companion object {
        const val REQUEST_CAPTURE = 19473
        private const val MAX_BYTES = 64L * 1024 * 1024
        private const val MAX_PIXELS = 40000000L
    }
}

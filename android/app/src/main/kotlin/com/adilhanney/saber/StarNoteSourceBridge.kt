package io.github.canele452.personalinkvault

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.Executors

internal class StarNoteSourceBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private class Selection(val id: String, val name: String, val uri: Uri) {
        @Volatile var cancelled = false
        var staging: MethodChannel.Result? = null
        var staged: Staged? = null
    }

    private data class Staged(val path: Path, val bytes: Long) {
        fun response(): Map<String, Any> = mapOf("path" to path.toString(), "bytes" to bytes)
    }

    private class SourceError(val code: String, message: String) : IOException(message)

    private val app = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "personal_ink_vault/starnote_source")
    private var chooser: MethodChannel.Result? = null
    private var selection: Selection? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "choose" -> if (call.arguments == null) choose(result) else invalidRequest(result)
                "stage", "release" -> {
                    val args = call.arguments as? Map<*, *>
                    val id = args?.get("id") as? String
                    if (args?.size != 1 || id == null || !identifier.matches(id)) {
                        invalidRequest(result)
                    } else if (call.method == "stage") {
                        stage(id, result)
                    } else {
                        release(id, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun choose(result: MethodChannel.Result) {
        if (chooser != null || selection != null) {
            result.error("busy", "StarNote 파일을 이미 가져오고 있습니다.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        chooser = result
        try {
            activity.startActivityForResult(intent, REQUEST_CHOOSE)
        } catch (_: RuntimeException) {
            chooser = null
            result.error("unavailable", "파일 선택기를 열지 못했습니다.", null)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CHOOSE) return false
        val result = chooser ?: return true
        if (resultCode != Activity.RESULT_OK) {
            chooser = null
            result.success(null)
            return true
        }
        val uri = chosenUri(data)
        if (uri == null) {
            chooser = null
            reportFailure(result, SecurityException())
            return true
        }
        files.execute {
            val outcome = runCatching {
                DocumentImportBridge.verifyGrant(app, uri)
                val name = DocumentImportBridge.displayName(app.contentResolver, uri)
                if (name == null || name.length <= 5 || !name.endsWith(".note", ignoreCase = true) ||
                    name.any { it == '/' || it == '\\' || it.isISOControl() }) {
                    throw SourceError("unsupported_type", "StarNote .note 파일을 선택해 주세요.")
                }
                val size = declaredSize(app.contentResolver, uri)
                if (size != null && size > DocumentIntake.MAX_FILE_BYTES) throw DocumentIntake.SizeLimitExceeded()
                Selection(UUID.randomUUID().toString(), name, uri)
            }
            main.post {
                if (chooser !== result) return@post
                chooser = null
                outcome.fold(
                    onSuccess = { chosen ->
                        selection = chosen
                        result.success(mapOf("id" to chosen.id, "name" to chosen.name))
                    },
                    onFailure = { reportFailure(result, it) },
                )
            }
        }
        return true
    }

    private fun stage(id: String, result: MethodChannel.Result) {
        val current = selection
        if (current == null || current.id != id) {
            result.error("stale", "파일 선택이 만료되었습니다. 다시 선택해 주세요.", null)
            return
        }
        current.staged?.let {
            result.success(it.response())
            return
        }
        if (current.staging != null) {
            result.error("busy", "StarNote 파일을 이미 읽고 있습니다.", null)
            return
        }
        current.staging = result
        files.execute {
            val outcome = runCatching { copySelection(current) }
            main.post {
                if (selection !== current || current.staging !== result) {
                    outcome.getOrNull()?.let { file -> files.execute { deleteQuietly(file.path) } }
                    return@post
                }
                current.staging = null
                outcome.fold(
                    onSuccess = { file ->
                        current.staged = file
                        result.success(file.response())
                    },
                    onFailure = { reportFailure(result, it) },
                )
            }
        }
    }

    private fun copySelection(current: Selection): Staged {
        if (current.cancelled) throw InterruptedIOException()
        DocumentImportBridge.verifyGrant(app, current.uri)
        val directory = app.cacheDir.toPath().toAbsolutePath().normalize().resolve("starnote-picker")
        Files.createDirectories(directory)
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw IOException("Invalid StarNote cache")
        if (!cachePrepared) {
            // Only the default-process picker uses this cache. Remove exact orphan filenames from prior processes.
            Files.newDirectoryStream(directory).use { previous ->
                for (file in previous) {
                    val name = file.fileName.toString()
                    if (ownedFilename.matches(name) && !name.startsWith(processPrefix) &&
                        Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) deleteQuietly(file)
                }
            }
            cachePrepared = true
        }
        val path = Files.createFile(directory.resolve("$processPrefix${current.id}.note"))
        var complete = false
        try {
            val bytes = DocumentIntake.copyBounded(
                path,
                DocumentIntake.MAX_FILE_BYTES,
                { app.contentResolver.openInputStream(current.uri) },
                { current.cancelled },
            )
            if (current.cancelled) throw InterruptedIOException()
            complete = true
            return Staged(path, bytes)
        } finally {
            if (!complete) deleteQuietly(path)
        }
    }

    private fun release(id: String, result: MethodChannel.Result?) {
        val current = selection
        if (current == null || current.id != id) {
            result?.success(null)
            return
        }
        selection = null
        current.cancelled = true
        current.staging?.let { reportFailure(it, InterruptedIOException()) }
        current.staging = null
        val path = current.staged?.path
        if (path == null) {
            result?.success(null)
            return
        }
        files.execute {
            val removed = deleteQuietly(path)
            if (result != null) main.post {
                if (removed) result.success(null)
                else result.error("release_failed", "StarNote 임시 파일을 정리하지 못했습니다.", null)
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        chooser?.success(null)
        chooser = null
        selection?.let { release(it.id, null) }
    }

    private fun invalidRequest(result: MethodChannel.Result) {
        result.error("invalid_request", "StarNote 파일 선택 정보를 확인해 주세요.", null)
    }

    private fun reportFailure(result: MethodChannel.Result, failure: Throwable) {
        when (failure) {
            is SourceError -> result.error(failure.code, failure.message, null)
            is DocumentIntake.SizeLimitExceeded -> result.error("too_large", "StarNote 파일은 128 MiB까지 가져올 수 있습니다.", null)
            is SecurityException -> result.error("invalid_source", "선택한 파일에 접근할 수 없습니다. 파일 선택기에서 다시 선택해 주세요.", null)
            is InterruptedIOException -> result.error("interrupted", "StarNote 파일 읽기가 중단되었습니다.", null)
            else -> result.error("read_failed", "StarNote 파일을 읽지 못했습니다.", null)
        }
    }

    companion object {
        private const val REQUEST_CHOOSE = 19474
        private const val UUID_PATTERN = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
        private val identifier = Regex(UUID_PATTERN)
        private val ownedFilename = Regex("starnote-${UUID_PATTERN}_${UUID_PATTERN}\\.note")
        private val processPrefix = "starnote-${UUID.randomUUID()}_"
        private val files = Executors.newSingleThreadExecutor()
        private var cachePrepared = false

        private fun chosenUri(data: Intent?): Uri? {
            if (data == null) return null
            return try {
                val clip = data.clipData
                if (clip != null && (clip.itemCount != 1 || clip.getItemAt(0).intent != null)) return null
                val uri = listOfNotNull(data.data, clip?.getItemAt(0)?.uri).distinct().singleOrNull()
                uri?.takeIf { it.scheme == ContentResolver.SCHEME_CONTENT && !it.authority.isNullOrEmpty() }
            } catch (_: RuntimeException) {
                null
            }
        }

        private fun declaredSize(resolver: ContentResolver, uri: Uri): Long? = try {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) cursor.getLong(column) else null
            }
        } catch (_: IllegalArgumentException) {
            null
        } catch (_: UnsupportedOperationException) {
            null
        }

        private fun deleteQuietly(path: Path): Boolean = try {
            if (Files.isSymbolicLink(path.parent)) throw IOException("Invalid StarNote cache")
            Files.deleteIfExists(path)
            true
        } catch (_: IOException) {
            Log.w("StarNoteSourceBridge", "Could not remove StarNote temporary file")
            false
        }
    }
}

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

internal class DocumentSourceBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val kind: Kind,
) {
    enum class Kind(val channel: String, val requestCode: Int, val prefix: String, val label: String) {
        STARNOTE("starnote_source", 19474, "starnote", "StarNote"),
        OFFICE("office_source", 19477, "office", "Office·한글"),
    }

    private class Selection(val id: String, val name: String, val uri: Uri) {
        val extension = name.substringAfterLast('.').lowercase(java.util.Locale.ROOT)
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
    private val channel = MethodChannel(messenger, "personal_ink_vault/${kind.channel}")
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
            result.error("busy", "${kind.label} 파일을 이미 가져오고 있습니다.", null)
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
            activity.startActivityForResult(intent, kind.requestCode)
        } catch (_: RuntimeException) {
            chooser = null
            result.error("unavailable", "파일 선택기를 열지 못했습니다.", null)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != kind.requestCode) return false
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
                val resolver = app.contentResolver
                val name = selectionName(resolver, uri)
                val size = declaredSize(resolver, uri)
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

    private fun selectionName(resolver: ContentResolver, uri: Uri): String {
        val name = DocumentImportBridge.displayName(resolver, uri)
        if (kind == Kind.STARNOTE) {
            if (name == null || name.length <= 5 || !name.endsWith(".note", ignoreCase = true) ||
                name.any { it == '/' || it == '\\' || it.isISOControl() }) {
                throw SourceError("unsupported_type", "StarNote .note 파일을 선택해 주세요.")
            }
            return name
        }
        try {
            val extension = DocumentIntake.documentFormat(null, resolver.getType(uri), name)
            if (extension != "pdf") return DocumentIntake.fileName(name, extension)
        } catch (_: IOException) {
            // Report a document type error before opening the provider stream.
        }
        throw SourceError("unsupported_type", "Word·PowerPoint·OpenDocument·한글 파일을 선택해 주세요.")
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
            result.error("busy", "${kind.label} 파일을 이미 읽고 있습니다.", null)
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
        val directory = app.cacheDir.toPath().toAbsolutePath().normalize().resolve("${kind.prefix}-picker")
        Files.createDirectories(directory)
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw IOException("Invalid document picker cache")
        val filenamePrefix = "${kind.prefix}-${processId}_"
        if (kind !in preparedCaches) {
            // Only the default-process picker uses this cache. Remove exact orphan filenames from prior processes.
            val extensions = if (kind == Kind.STARNOTE) "note" else "doc|docx|ppt|pptx|odt|odp|hwp|hwpx"
            val owned = Regex("${kind.prefix}-${UUID_PATTERN}_${UUID_PATTERN}\\.(?:$extensions)")
            Files.newDirectoryStream(directory).use { previous ->
                for (file in previous) {
                    val name = file.fileName.toString()
                    if (owned.matches(name) && !name.startsWith(filenamePrefix) &&
                        Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) deleteQuietly(file)
                }
            }
            preparedCaches.add(kind)
        }
        val path = Files.createFile(directory.resolve("$filenamePrefix${current.id}.${current.extension}"))
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
                else result.error("release_failed", "문서 임시 파일을 정리하지 못했습니다.", null)
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
        result.error("invalid_request", "문서 선택 정보를 확인해 주세요.", null)
    }

    private fun reportFailure(result: MethodChannel.Result, failure: Throwable) {
        when (failure) {
            is SourceError -> result.error(failure.code, failure.message, null)
            is DocumentIntake.SizeLimitExceeded -> result.error("too_large", "${kind.label} 파일은 128 MiB까지 가져올 수 있습니다.", null)
            is SecurityException -> result.error("invalid_source", "선택한 파일에 접근할 수 없습니다. 파일 선택기에서 다시 선택해 주세요.", null)
            is InterruptedIOException -> result.error("interrupted", "문서 읽기가 중단되었습니다.", null)
            else -> result.error("read_failed", "문서를 읽지 못했습니다.", null)
        }
    }

    companion object {
        private const val UUID_PATTERN = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
        private val identifier = Regex(UUID_PATTERN)
        private val processId = UUID.randomUUID().toString()
        private val files = Executors.newSingleThreadExecutor()
        private val preparedCaches = mutableSetOf<Kind>()

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
            if (Files.isSymbolicLink(path.parent)) throw IOException("Invalid document picker cache")
            Files.deleteIfExists(path)
            true
        } catch (_: IOException) {
            Log.w("DocumentSourceBridge", "Could not remove document temporary file")
            false
        }
    }
}

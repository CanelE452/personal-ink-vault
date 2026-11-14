package io.github.canele452.personalinkvault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.Executors

internal class ObsidianFolderBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private class Pick(val result: MethodChannel.Result) {
        val id = UUID.randomUUID().toString()
        val cancellation = CancellationSignal()
        var path: Path? = null
    }

    private val app = activity.applicationContext
    private val channel = MethodChannel(messenger, "personal_ink_vault/obsidian_folder")
    private var pending: Pick? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> pick(result)
                "release" -> {
                    pending?.takeIf { it.id == call.argument<String>("id") && it.path != null }
                        ?.let(::release)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "이미 Obsidian 보관함을 가져오고 있습니다.", null)
            return
        }
        pending = Pick(result)
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, REQUEST_FOLDER)
        } catch (_: RuntimeException) {
            pending = null
            result.error("unavailable", "Android 폴더 선택기를 열지 못했습니다.", null)
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_FOLDER) return false
        val pick = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            pick.result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content" || uri.authority.isNullOrEmpty() ||
            !DocumentsContract.isTreeUri(uri)) {
            pending = null
            reportFailure(pick, SecurityException())
            return true
        }
        worker.execute {
            val outcome = runCatching { stage(uri, pick) }
            activity.runOnUiThread {
                if (pending !== pick) {
                    outcome.getOrNull()?.let { (path, _) -> worker.execute { delete(path) } }
                } else {
                    outcome.fold(
                        onSuccess = { (path, name) ->
                            pick.path = path
                            pick.result.success(mapOf("id" to pick.id, "name" to name))
                        },
                        onFailure = {
                            pending = null
                            reportFailure(pick, it)
                        },
                    )
                }
            }
        }
        return true
    }

    private fun stage(uri: Uri, pick: Pick): Pair<Path, String> {
        pick.cancellation.throwIfCanceled()
        DocumentImportBridge.verifyGrant(app, uri)
        val resolver = app.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(uri)
        val root = DocumentsContract.buildDocumentUriUsingTree(uri, rootId)
        val name = DocumentImportBridge.displayName(resolver, root)?.trim()?.takeIf { it.isNotEmpty() }
            ?: "Obsidian"
        val source = object : ObsidianFolderStager.Tree {
            override fun children(directoryId: String, visitor: ObsidianFolderStager.ChildVisitor) {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, directoryId)
                resolver.query(children, columns, null, null, null, pick.cancellation)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        visitor.accept(ObsidianFolderStager.Entry(
                            cursor.getString(0), cursor.getString(1),
                            cursor.getString(2) == Document.MIME_TYPE_DIR,
                        ))
                    }
                } ?: throw IOException("Missing provider directory")
            }

            override fun open(fileId: String): InputStream {
                val file = DocumentsContract.buildDocumentUriUsingTree(uri, fileId)
                val descriptor = resolver.openAssetFileDescriptor(file, "r", pick.cancellation)
                    ?: throw IOException("Missing provider file")
                try {
                    return descriptor.createInputStream()
                } catch (error: IOException) {
                    descriptor.close()
                    throw error
                }
            }
        }
        val cache = app.cacheDir.toPath().resolve("obsidian-picker")
        Files.createDirectories(cache)
        if (!Files.isDirectory(cache, LinkOption.NOFOLLOW_LINKS)) throw IOException("Invalid folder cache")
        if (!cachePrepared) {
            Files.newDirectoryStream(cache).use { entries ->
                for (entry in entries) if (identifier.matches(entry.fileName.toString())) delete(entry)
            }
            cachePrepared = true
        }
        val path = cache.resolve(pick.id)
        ObsidianFolderStager.stage(source, rootId, path) { pick.cancellation.isCanceled }
        return path to name
    }

    private fun release(pick: Pick) {
        pending = null
        pick.cancellation.cancel()
        pick.path?.let { path -> worker.execute { delete(path) } }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pending?.let { pick ->
            if (pick.path == null) pick.result.success(null)
            release(pick)
        }
    }

    private fun reportFailure(pick: Pick, error: Throwable) {
        val message = when (error) {
            is OperationCanceledException, is InterruptedIOException -> {
                pick.result.success(null)
                return
            }
            is ObsidianFolderStager.InvalidFolder -> error.message
            is DocumentIntake.SizeLimitExceeded -> "Obsidian 보관함이 가져오기 용량 한도를 초과했습니다."
            is SecurityException -> "선택한 폴더에 접근할 수 없습니다. 기기의 파일 선택기에서 다시 선택해 주세요."
            else -> "Obsidian 보관함 폴더를 읽지 못했습니다."
        }
        pick.result.error("folder_import_failed", message, null)
    }

    companion object {
        private const val REQUEST_FOLDER = 19476
        private val identifier = Regex("[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
        private val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        private val worker = Executors.newSingleThreadExecutor()
        private var cachePrepared = false

        private fun delete(path: Path) {
            try {
                ObsidianFolderStager.remove(path)
            } catch (_: IOException) {
                Log.w("ObsidianFolderBridge", "Could not remove the staged vault folder")
            }
        }
    }
}

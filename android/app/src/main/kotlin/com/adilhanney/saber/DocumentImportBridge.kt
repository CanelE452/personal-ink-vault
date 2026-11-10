package io.github.canele452.personalinkvault

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.OpenableColumns
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal object DocumentImportBridge {
    private const val CHANNEL = "personal_ink_vault/document_import"
    private const val OPEN_FAILED = "문서를 가져오지 못했습니다. 지원 형식, 공유 권한과 파일 크기를 확인해 주세요."
    private val main = Handler(Looper.getMainLooper())
    private val files = Executors.newSingleThreadExecutor()
    private val releases = Executors.newSingleThreadExecutor()
    private lateinit var intake: DocumentIntake
    private val clients = linkedSetOf<MethodChannel>()
    private var attached: MethodChannel? = null
    private var copying = 0

    fun handles(intent: Intent): Boolean {
        val typed = DocumentIntake.extensionForMime(intent.type) != null
        return when (intent.action) {
            Intent.ACTION_VIEW -> typed || (DocumentIntake.genericMime(intent.type) && fileUri(intent.data))
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> typed || try {
                val clip = intent.clipData
                intent.hasExtra(Intent.EXTRA_STREAM) || fileUri(intent.data) ||
                    (clip != null && (clip.itemCount > 64 || (0 until clip.itemCount).any {
                        val item = clip.getItemAt(it)
                        item.uri != null || item.intent != null
                    }))
            } catch (_: RuntimeException) {
                true
            }
            else -> false
        }
    }

    private fun fileUri(uri: Uri?): Boolean =
        uri?.scheme == ContentResolver.SCHEME_CONTENT || uri?.scheme == ContentResolver.SCHEME_FILE

    fun attach(context: Context, messenger: BinaryMessenger): MethodChannel {
        initialize(context.applicationContext)
        val channel = MethodChannel(messenger, CHANNEL)
        clients.add(channel)
        attached = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> result.success(if (attached === channel) intake.claim(channel) else emptyList<Any>())
                "release" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val id = arguments?.get("id") as? String
                    if (arguments?.size != 1 || id == null || id.length != 36) {
                        result.error("invalid_request", "가져온 문서 식별자를 확인해 주세요.", null)
                    } else if (intake.beginRelease(channel, id)) {
                        releases.execute {
                            try {
                                intake.release(id)
                                main.post { result.success(null) }
                            } catch (_: Exception) {
                                main.post {
                                    result.error("release_failed", "임시 문서 파일을 정리하지 못했습니다.", null)
                                    changed()
                                }
                            }
                        }
                    } else result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun initialize(app: Context) {
        if (::intake.isInitialized) return
        intake = DocumentIntake(app.noBackupFilesDir)
        files.execute {
            try {
                intake.restore()
                main.post { changed() }
            } catch (_: Exception) {
                main.post { notifyFailure(app) }
            }
        }
    }

    fun activate(channel: MethodChannel) {
        if (clients.remove(channel)) {
            clients.add(channel)
            attached = channel
            changed()
        }
    }

    fun detach(channel: MethodChannel) {
        if (!clients.remove(channel)) return
        channel.setMethodCallHandler(null)
        intake.abandon(channel)
        if (attached === channel) attached = clients.lastOrNull()
        changed()
    }

    fun accept(context: Context, intent: Intent) {
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        val app = context.applicationContext
        val mime = intent.type
        val uri = try {
            documentUri(intent)
        } catch (_: RuntimeException) {
            null
        }
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrEmpty()) {
            notifyFailure(app)
            return
        }
        if (copying >= DocumentIntake.MAX_ENTRIES) {
            Toast.makeText(app, "받은 문서가 많습니다. 잠시 후 다시 시도해 주세요.", Toast.LENGTH_LONG).show()
            return
        }
        initialize(app)
        copying++
        files.execute {
            val success = try {
                verifyGrant(app, uri)
                val resolver = app.contentResolver
                val name = displayName(resolver, uri)
                val format = DocumentIntake.documentFormat(mime, resolver.getType(uri), name)
                intake.stage(format, name) { resolver.openInputStream(uri) }
                true
            } catch (_: Exception) {
                false
            }
            main.post {
                copying--
                if (success) changed()
                else notifyFailure(app)
            }
        }
    }

    private fun changed() {
        attached?.invokeMethod("documentsChanged", null)
    }

    @Suppress("DEPRECATION")
    private fun documentUri(intent: Intent): Uri? {
        if (intent.action == Intent.ACTION_VIEW) return intent.data
        if (intent.action != Intent.ACTION_SEND) return null
        val clip = intent.clipData
        if (clip != null && clip.itemCount != 1) return null
        val alternatives = listOfNotNull(
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM),
            clip?.getItemAt(0)?.uri,
            intent.data,
        )
        return alternatives.distinct().singleOrNull()
    }

    fun verifyGrant(context: Context, uri: Uri) {
        val authority = requireNotNull(uri.authority).substringAfter('@')
        val packageName = context.packageName
        if (authority == packageName || authority.startsWith("$packageName.") ||
            context.packageManager.resolveContentProvider(authority, 0)?.packageName == packageName ||
            context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("External read grant required")
        }
    }

    fun displayName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
        }
    } catch (_: IllegalArgumentException) {
        null
    } catch (_: UnsupportedOperationException) {
        null
    }

    private fun notifyFailure(context: Context) {
        Toast.makeText(context, OPEN_FAILED, Toast.LENGTH_LONG).show()
    }
}

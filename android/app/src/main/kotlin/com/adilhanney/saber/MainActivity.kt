package io.github.canele452.personalinkvault

import android.os.Bundle
import android.content.Intent
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.canele452.personalinkvault.office.HwpEditorBridge
import io.github.canele452.personalinkvault.office.OfficeEngineBridge
import android.content.Intent.FLAG_ACTIVITY_NEW_TASK

class MainActivity: FlutterActivity() {
    private var officeBridge: OfficeEngineBridge? = null
    private var hwpEditorBridge: HwpEditorBridge? = null
    private var cameraBridge: CameraBridge? = null
    private var documentChannel: MethodChannel? = null
    private var starNoteSourceBridge: DocumentSourceBridge? = null
    private var officeSourceBridge: DocumentSourceBridge? = null
    private var obsidianFolderBridge: ObsidianFolderBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documentChannel = DocumentImportBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        starNoteSourceBridge = DocumentSourceBridge(this, messenger, DocumentSourceBridge.Kind.STARNOTE)
        officeSourceBridge = DocumentSourceBridge(this, messenger, DocumentSourceBridge.Kind.OFFICE)
        obsidianFolderBridge = ObsidianFolderBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        val bridge = OfficeEngineBridge(this)
        officeBridge = bridge
        val hwpEditor = HwpEditorBridge(this)
        hwpEditorBridge = hwpEditor
        val camera = CameraBridge(this)
        cameraBridge = camera
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "personal_ink_vault/camera")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(camera.capabilities())
                    "capture" -> camera.capture(object : CameraBridge.Completion {
                        override fun success(value: Map<String, Any>?) { result.success(value) }
                        override fun error(code: String, message: String) { result.error(code, message, null) }
                    })
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "personal_ink_vault/office_engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(bridge.capabilities())
                    "hwpEdit" -> hwpEditor.edit(call.argument<String>("sourcePath"), call.argument<String>("sessionId"),
                        call.argument<String>("fileName"),
                        object : HwpEditorBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    "edit" -> bridge.edit(call.argument<String>("sourcePath"), call.argument<String>("sessionId"),
                        object : OfficeEngineBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    "preview" -> bridge.preview(call.argument<String>("sourcePath"), call.argument<String>("sessionId"),
                        object : OfficeEngineBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    "inspect" -> {
                        val arguments = call.arguments as? Map<*, *>
                        if (arguments == null || arguments.keys != setOf("sourcePath", "sessionId", "inputSourceSha256") ||
                            arguments["sourcePath"] !is String || arguments["sessionId"] !is String ||
                            arguments["inputSourceSha256"] !is String) {
                            result.error("invalid_request", "관측할 원본과 세션을 확인하세요.", null)
                        } else {
                            bridge.inspect(arguments["sourcePath"] as String, arguments["sessionId"] as String,
                                arguments["inputSourceSha256"] as String,
                                object : OfficeEngineBridge.Completion {
                                    override fun success(value: Map<String, Any>) { result.success(value) }
                                    override fun error(code: String, message: String) { result.error(code, message, null) }
                                })
                        }
                    }
                    "releasePreview" -> bridge.releasePreview(call.argument<String>("sessionId"),
                        object : OfficeEngineBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    "convertLegacy" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val sourcePath = arguments?.get("sourcePath") as? String
                        val sessionId = arguments?.get("sessionId") as? String
                        val inputHash = arguments?.get("inputSourceSha256") as? String
                        if (arguments?.keys != setOf("sourcePath", "sessionId", "inputSourceSha256") ||
                            sourcePath == null || sessionId == null || inputHash == null) {
                            result.error("invalid_request", "변환할 구형 문서 원본과 세션을 확인하세요.", null)
                        } else {
                            bridge.convertLegacy(sourcePath, sessionId, inputHash,
                                object : OfficeEngineBridge.Completion {
                                    override fun success(value: Map<String, Any>) { result.success(value) }
                                    override fun error(code: String, message: String) { result.error(code, message, null) }
                                })
                        }
                    }
                    "validateLegacySource" -> {
                        val arguments = call.arguments as? Map<*, *>
                        bridge.validateLegacySource(arguments?.get("sourcePath") as? String,
                            arguments?.get("format") as? String, arguments?.get("sourceSha256") as? String,
                            object : OfficeEngineBridge.Completion {
                                override fun success(value: Map<String, Any>) { result.success(value) }
                                override fun error(code: String, message: String) { result.error(code, message, null) }
                            })
                    }
                    "recover" -> bridge.recover(call.argument<String>("sessionId"), call.argument<String>("inputSourceSha256"),
                        object : OfficeEngineBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    "resume" -> bridge.resume(call.argument<String>("sessionId"), call.argument<String>("inputSourceSha256"),
                        object : OfficeEngineBridge.Completion {
                            override fun success(value: Map<String, Any>) { result.success(value) }
                            override fun error(code: String, message: String) { result.error(code, message, null) }
                        })
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (obsidianFolderBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (starNoteSourceBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (officeSourceBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (cameraBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (officeBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (hwpEditorBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        documentChannel?.let { DocumentImportBridge.detach(it) }
        documentChannel = null
        obsidianFolderBridge?.dispose()
        obsidianFolderBridge = null
        starNoteSourceBridge?.dispose()
        starNoteSourceBridge = null
        officeSourceBridge?.dispose()
        officeSourceBridge = null
        cameraBridge?.dispose()
        cameraBridge = null
        officeBridge?.dispose()
        officeBridge = null
        hwpEditorBridge = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val launch = intent
        val restarting = try {
            launch.getIntExtra("org.chromium.chrome.extra.TASK_ID", -1) == this.taskId
        } catch (_: RuntimeException) {
            false
        }
        if (restarting) {
            this.finish()
            launch.addFlags(FLAG_ACTIVITY_NEW_TASK)
            startActivity(launch)
        }
        val isDocument = DocumentImportBridge.handles(launch)
        if (isDocument) setIntent(Intent())
        super.onCreate(savedInstanceState)
        if (isDocument && !restarting && savedInstanceState == null) DocumentImportBridge.accept(this, launch)

        WindowCompat.setDecorFitsSystemWindows(window, false)

        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightNavigationBars = true
    }

    override fun onResume() {
        super.onResume()
        documentChannel?.let { DocumentImportBridge.activate(it) }
    }

    override fun onNewIntent(intent: Intent) {
        if (!DocumentImportBridge.handles(intent)) {
            super.onNewIntent(intent)
            return
        }
        val neutral = Intent()
        setIntent(neutral)
        super.onNewIntent(neutral)
        documentChannel?.let { DocumentImportBridge.activate(it) }
        DocumentImportBridge.accept(this, intent)
    }
}

package io.github.canele452.personalinkvault

import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognition
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModel
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModelIdentifier
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognizer
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognizerOptions
import com.google.mlkit.vision.digitalink.recognition.Ink
import com.google.mlkit.vision.digitalink.recognition.RecognitionContext
import com.google.mlkit.vision.digitalink.recognition.WritingArea
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handwriting recognition with ML Kit digital ink (channel personal_ink_vault/handwriting).
 * - modelStatus {language} -> "ready" | "missing"
 * - downloadModel {language} -> null when the language model is on the device; error "download_failed" otherwise
 * - recognize {language, width, height, strokes: [[x0, y0, x1, y1, ...], ...]} -> up to 5 readings, best first;
 *   points are in the writing area's units (width × height). Error "model_missing" before the model is downloaded.
 * Any failure to start the engine is reported as "unavailable".
 */
class HandwritingBridge(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val recognizers = HashMap<String, DigitalInkRecognizer>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val language = call.argument<String>("language") ?: "ko"
        if (language !in LANGUAGES) {
            result.error("invalid_request", "지원하지 않는 언어입니다: $language", null)
            return
        }
        try {
            val model = DigitalInkRecognitionModel.builder(
                DigitalInkRecognitionModelIdentifier.fromLanguageTag(language)
                    ?: throw IllegalStateException("no model for $language"),
            ).build()
            val manager = RemoteModelManager.getInstance()
            when (call.method) {
                "modelStatus" -> manager.isModelDownloaded(model)
                    .addOnSuccessListener { result.success(if (it) "ready" else "missing") }
                    .addOnFailureListener { result.error("unavailable", it.message, null) }
                "downloadModel" -> manager.download(model, DownloadConditions.Builder().build())
                    .addOnSuccessListener { result.success(null) }
                    .addOnFailureListener { result.error("download_failed", it.message ?: "모델을 받지 못했습니다.", null) }
                "recognize" -> manager.isModelDownloaded(model)
                    .addOnSuccessListener { ready ->
                        if (ready) recognize(call, language, model, result)
                        else result.error("model_missing", "손글씨 모델을 먼저 받아야 합니다.", null)
                    }
                    .addOnFailureListener { result.error("unavailable", it.message, null) }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            // A missing native library or a broken ML Kit setup must not crash the app.
            result.error("unavailable", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun recognize(
        call: MethodCall,
        language: String,
        model: DigitalInkRecognitionModel,
        result: MethodChannel.Result,
    ) {
        val width = (call.argument<Number>("width") ?: 0).toFloat()
        val height = (call.argument<Number>("height") ?: 0).toFloat()
        val strokes = call.argument<List<List<Number>>>("strokes") ?: emptyList()
        val ink = Ink.builder()
        var time = System.currentTimeMillis()
        for (stroke in strokes) {
            if (stroke.size < 2) continue
            val builder = Ink.Stroke.builder()
            for (index in 0 until stroke.size - 1 step 2) {
                // The page stores no timestamps; ML Kit wants increasing ones, so points are 10 ms apart and
                // strokes 200 ms apart.
                builder.addPoint(Ink.Point.create(stroke[index].toFloat(), stroke[index + 1].toFloat(), time))
                time += 10
            }
            ink.addStroke(builder.build())
            time += 200
        }
        if (ink.isEmpty) {
            result.success(emptyList<String>())
            return
        }
        try {
            val recognizer = recognizers.getOrPut(language) {
                DigitalInkRecognition.getClient(DigitalInkRecognizerOptions.builder(model).setMaxResultCount(5).build())
            }
            val context = RecognitionContext.builder().setPreContext("")
                .apply { if (width > 0 && height > 0) setWritingArea(WritingArea(width, height)) }
                .build()
            recognizer.recognize(ink.build(), context)
                .addOnSuccessListener { recognition ->
                    result.success(recognition.candidates.map { it.text }.filter { it.isNotBlank() })
                }
                .addOnFailureListener { result.error("recognize_failed", it.message, null) }
        } catch (error: Throwable) {
            result.error("unavailable", error.message ?: error.javaClass.simpleName, null)
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        for (recognizer in recognizers.values) {
            try {
                recognizer.close()
            } catch (_: Throwable) {
            }
        }
        recognizers.clear()
    }

    companion object {
        const val CHANNEL = "personal_ink_vault/handwriting"
        val LANGUAGES = setOf("ko", "en-US")
    }
}

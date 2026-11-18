package io.github.canele452.personalinkvault

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * The app side of the reminder and calendar: widget contents, reminder alarms, the notification permission and
 * which planner screen a widget or notification asked to open.
 */
class PlannerBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var permissionReply: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val kind = call.argument<String>("kind")
                    val payload = call.argument<String>("payload")
                    if (kind !in PlannerWidgets.KINDS || payload == null || !isJsonObject(payload)) {
                        result.error("invalid_request", "위젯 내용을 확인하세요.", null)
                    } else {
                        PlannerWidgets.save(activity, kind!!, payload)
                        PlannerWidgets.refresh(activity, kind)
                        PlannerTickReceiver.schedule(activity)
                        result.success(null)
                    }
                }
                "scheduleReminders" -> {
                    val items = call.argument<List<Map<String, Any?>>>("items")
                    if (items == null) {
                        result.error("invalid_request", "알림 목록을 확인하세요.", null)
                    } else {
                        val array = JSONArray()
                        for (item in items) {
                            val id = item["id"] as? String
                            val title = item["title"] as? String
                            val at = (item["at"] as? Number)?.toLong()
                            if (id.isNullOrEmpty() || title == null || at == null) continue
                            array.put(JSONObject().put("id", id).put("title", title).put("at", at))
                        }
                        ReminderAlarms.replaceAll(activity, array)
                        result.success(status(activity))
                    }
                }
                "notificationStatus" -> result.success(status(activity))
                "requestNotificationPermission" -> requestPermission(result)
                "takeLaunchTarget" -> {
                    result.success(launchTarget)
                    launchTarget = null
                }
                else -> result.notImplemented()
            }
        }
    }

    /** A widget or notification was tapped while the app was already open. */
    fun open(target: String) {
        channel.invokeMethod("open", target)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val reply = permissionReply ?: return true
        permissionReply = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        reply.success(status(activity) + ("granted" to granted))
        return true
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(status(activity))
            return
        }
        if (permissionReply != null) {
            result.error("busy", "알림 권한을 묻는 중입니다.", null)
            return
        }
        permissionReply = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    companion object {
        const val CHANNEL = "personal_ink_vault/planner"
        const val EXTRA_OPEN = "piv.open"
        private const val PERMISSION_REQUEST = 4207

        /** What a widget or notification asked to open when it started the app; Dart takes it once. */
        @Volatile
        var launchTarget: String? = null

        fun targetOf(intent: Intent?): String? =
            intent?.getStringExtra(EXTRA_OPEN)?.takeIf { it == "calendar" || it == "reminder" }

        fun status(context: Context): Map<String, Any> {
            val notifications = context.getSystemService(NotificationManager::class.java)
            val alarms = context.getSystemService(AlarmManager::class.java)
            val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
            return mapOf("granted" to notifications.areNotificationsEnabled(), "exact" to exact)
        }

        private fun isJsonObject(text: String): Boolean = try {
            JSONObject(text)
            true
        } catch (_: Exception) {
            false
        }
    }
}

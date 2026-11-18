package io.github.canele452.personalinkvault

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject

/** Reminder alarms: one exact (or, if exact alarms are not allowed, allow-while-idle) alarm per timed item. */
object ReminderAlarms {
    private const val PREFS = "piv_planner"
    private const val KEY = "reminder_alarms"
    const val EXTRA_ID = "piv.reminderId"
    const val EXTRA_TITLE = "piv.reminderTitle"

    fun replaceAll(context: Context, items: JSONArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val old = try {
            JSONArray(prefs.getString(KEY, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        val listed = HashSet<String>()
        for (index in 0 until items.length()) {
            val id = items.optJSONObject(index)?.optString("id") ?: continue
            if (id.isNotEmpty()) listed.add(id)
        }
        val alarms = context.getSystemService(AlarmManager::class.java)
        val now = System.currentTimeMillis()
        for (index in 0 until old.length()) {
            val entry = old.optJSONObject(index) ?: continue
            val id = entry.optString("id")
            // A listed reminder is replaced by schedule() below. A one-time reminder that is due may not have
            // been delivered yet (inexact alarms come late), so cancelling it would lose it; it is left to fire.
            // A repeating one that is no longer listed was finished or deleted, so its next alarm goes.
            val due = entry.optInt("step") <= 0 && entry.optLong("at") <= now
            if (id.isEmpty() || id in listed || due) continue
            alarms.cancel(pending(context, id, "", PendingIntent.FLAG_UPDATE_CURRENT))
        }
        prefs.edit().putString(KEY, items.toString()).apply()
        schedule(context, items)
    }

    /** The first time after [now], stepping a repeating reminder by whole days in local time. */
    fun nextAt(at: Long, stepDays: Int, now: Long): Long {
        if (stepDays <= 0 || at > now) return at
        val time = Calendar.getInstance().apply { timeInMillis = at }
        var days = 0
        while (time.timeInMillis <= now) {
            days += stepDays
            time.timeInMillis = at
            time.add(Calendar.DAY_OF_MONTH, days)
        }
        return time.timeInMillis
    }

    /** After a repeating reminder rang, its next alarm is set from the saved list. */
    fun rearm(context: Context, id: String) {
        val items = try {
            JSONArray(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]"))
        } catch (_: Exception) {
            return
        }
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            if (item.optString("id") == id && item.optInt("step") > 0) {
                scheduleOne(context, item, System.currentTimeMillis() + 1_000)
                return
            }
        }
    }

    /** After a reboot or a clock change the saved list is scheduled again. */
    fun restore(context: Context) {
        val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]")
        val items = try {
            JSONArray(text)
        } catch (_: Exception) {
            return
        }
        schedule(context, items)
    }

    private fun schedule(context: Context, items: JSONArray) {
        val now = System.currentTimeMillis()
        for (index in 0 until items.length()) {
            scheduleOne(context, items.optJSONObject(index) ?: continue, now)
        }
    }

    /** One alarm at the item's next time after [now]; a past one-time reminder gets none. */
    private fun scheduleOne(context: Context, item: JSONObject, now: Long) {
        val id = item.optString("id")
        val at = nextAt(item.optLong("at"), item.optInt("step"), now)
        if (id.isEmpty() || at <= now) return
        val alarms = context.getSystemService(AlarmManager::class.java)
        val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
        val operation = pending(context, id, item.optString("title"), PendingIntent.FLAG_UPDATE_CURRENT)
        try {
            if (exact) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
            }
        } catch (_: SecurityException) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
        }
    }

    private fun pending(context: Context, id: String, title: String, flags: Int): PendingIntent {
        // The data URI keeps one alarm per reminder; extras do not take part in PendingIntent identity.
        val intent = Intent(context, ReminderAlarmReceiver::class.java)
            .setData(Uri.parse("piv-reminder://item/" + Uri.encode(id)))
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_TITLE, title)
        return PendingIntent.getBroadcast(context, 0, intent, flags or PendingIntent.FLAG_IMMUTABLE)
    }
}

/** Shows the reminder's notification; tapping it opens the reminder screen. */
class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(ReminderAlarms.EXTRA_ID) ?: return
        // A repeating reminder's next alarm is set first, so it keeps ringing even while notifications are off,
        // and the reminder widget is redrawn so it shows the next time instead of the one that just passed.
        ReminderAlarms.rearm(context, id)
        PlannerWidgets.refresh(context, "reminder")
        val title = intent.getStringExtra(ReminderAlarms.EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: "리마인더"
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "리마인더", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "리마인더에서 시간을 정한 할 일"
            },
        )
        // REORDER_TO_FRONT brings the running app forward even when an Office editor sits above it in the task,
        // instead of starting a second copy of the app on top.
        val open = Intent(context, MainActivity::class.java)
            .putExtra(PlannerBridge.EXTRA_OPEN, "reminder")
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
            )
        val content = PendingIntent.getActivity(
            context, 2, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText("리마인더")
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(content)
            .setAutoCancel(true)
            .build()
        manager.notify(id.hashCode(), notification)
    }

    companion object {
        const val CHANNEL = "piv_reminders"
    }
}

/** Reschedules reminder alarms and the widgets' midnight redraw after a reboot, an update or a clock change. */
class PlannerBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> {
                ReminderAlarms.restore(context)
                PlannerWidgets.refreshAll(context)
                PlannerTickReceiver.schedule(context)
            }
        }
    }
}

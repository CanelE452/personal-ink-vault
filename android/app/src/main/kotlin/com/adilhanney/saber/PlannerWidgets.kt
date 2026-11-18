package io.github.canele452.personalinkvault

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.text.TextPaint
import android.text.TextUtils
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Home-screen widgets for the reminder and the calendar. The app hands over their contents as JSON
 * (PlannerBridge "updateWidget"); this side draws the picture itself, so a new size, midnight or a reboot
 * redraws it without starting Flutter.
 */
object PlannerWidgets {
    val KINDS = setOf("calendar", "reminder")
    private const val DIR = "planner-widgets"
    private const val MAX_PIXELS = 1_200_000

    fun save(context: Context, kind: String, payload: String) {
        val dir = File(context.filesDir, DIR).apply { mkdirs() }
        val target = File(dir, "$kind.json")
        val temp = File(dir, "$kind.json.tmp")
        // A full disk must not crash the app: the widget keeps its last content until the next send.
        try {
            temp.writeText(payload)
            if (!temp.renameTo(target)) {
                target.delete()
                temp.renameTo(target)
            }
        } catch (_: Exception) {
            temp.delete()
        }
    }

    fun load(context: Context, kind: String): JSONObject? = try {
        JSONObject(File(File(context.filesDir, DIR), "$kind.json").readText())
    } catch (_: Exception) {
        null
    }

    fun refresh(context: Context, kind: String) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val provider = if (kind == "calendar") CalendarWidgetProvider::class.java else ReminderWidgetProvider::class.java
        for (id in manager.getAppWidgetIds(ComponentName(context, provider))) draw(context, manager, id, kind)
    }

    fun refreshAll(context: Context) {
        for (kind in KINDS) refresh(context, kind)
    }

    fun draw(context: Context, manager: AppWidgetManager, id: Int, kind: String) {
        val options: Bundle = manager.getAppWidgetOptions(id)
        val density = context.resources.displayMetrics.density
        val portrait = context.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        // Launchers give the portrait size as min width × max height and the landscape one as max width × min height.
        val widthDp = options.getInt(
            if (portrait) AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH else AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH,
        )
        val heightDp = options.getInt(
            if (portrait) AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT else AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,
        )
        var scale = density
        var width = (if (widthDp > 0) widthDp else 250) * scale
        var height = (if (heightDp > 0) heightDp else 180) * scale
        if (width * height > MAX_PIXELS) {
            val shrink = sqrt(MAX_PIXELS / (width * height))
            scale *= shrink
            width *= shrink
            height *= shrink
        }
        val payload = load(context, kind)
        val bitmap = if (kind == "calendar") {
            PlannerRenderer.calendar(payload, width.toInt(), height.toInt(), scale, Calendar.getInstance())
        } else {
            PlannerRenderer.reminders(payload, width.toInt(), height.toInt(), scale, System.currentTimeMillis())
        }
        val views = RemoteViews(context.packageName, R.layout.zz_piv_widget)
        views.setImageViewBitmap(R.id.zz_piv_widget_image, bitmap)
        views.setOnClickPendingIntent(R.id.zz_piv_widget_image, launch(context, kind))
        manager.updateAppWidget(id, views)
    }

    private fun launch(context: Context, kind: String): PendingIntent {
        // REORDER_TO_FRONT: an Office editor above the app in its task must not get a second app copy on top.
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(PlannerBridge.EXTRA_OPEN, kind)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
            )
        return PendingIntent.getActivity(
            context,
            if (kind == "calendar") 1 else 3,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class CalendarWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) PlannerWidgets.draw(context, manager, id, "calendar")
        PlannerTickReceiver.schedule(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        PlannerWidgets.draw(context, manager, id, "calendar")
    }
}

class ReminderWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) PlannerWidgets.draw(context, manager, id, "reminder")
        PlannerTickReceiver.schedule(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        PlannerWidgets.draw(context, manager, id, "reminder")
    }
}

/** Redraws both widgets just after midnight (today's mark, a new month, overdue reminders). */
class PlannerTickReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PlannerWidgets.refreshAll(context)
        schedule(context)
    }

    companion object {
        fun schedule(context: Context) {
            val next = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 5)
                set(Calendar.MILLISECOND, 0)
            }
            val operation = PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, PlannerTickReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            context.getSystemService(AlarmManager::class.java)
                .setAndAllowWhileIdle(AlarmManager.RTC, next.timeInMillis, operation)
        }
    }
}

/** Draws the widget pictures from the JSON the app saved. Colours follow the app's light planner screens. */
internal object PlannerRenderer {
    private val INK = Color.parseColor("#202124")
    private val GREY = Color.parseColor("#5F6368")
    private val FAINT = Color.parseColor("#BDC1C6")
    private val LINE = Color.parseColor("#E8EAED")
    private val SUNDAY = Color.parseColor("#D93025")
    private val SATURDAY = Color.parseColor("#1A73E8")
    private val ACCENT = Color.parseColor("#3D5AFE")
    private val MEMO = Color.parseColor("#FFF8E1")

    private fun background(canvas: Canvas, width: Int, height: Int, dp: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), 18 * dp, 18 * dp, paint)
    }

    private fun text(size: Float, color: Int, bold: Boolean = false) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = size
        this.color = color
        typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
    }

    private fun fit(text: String, paint: TextPaint, width: Float): String =
        TextUtils.ellipsize(text, paint, max(0f, width), TextUtils.TruncateAt.END).toString()

    private fun color(value: String?, fallback: Int): Int = try {
        if (value == null) fallback else Color.parseColor(value)
    } catch (_: IllegalArgumentException) {
        fallback
    }

    /** Draws normalized strokes ([x0, y0, x1, y1, …] in 0..1 of [area]); width is a fraction of the area width. */
    private fun strokes(canvas: Canvas, list: JSONArray?, area: RectF) {
        if (list == null) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        for (index in 0 until list.length()) {
            val stroke = list.optJSONObject(index) ?: continue
            val points = stroke.optJSONArray("points") ?: continue
            if (points.length() < 2) continue
            paint.color = color(stroke.optString("color", "#000000"), INK)
            paint.strokeWidth = max(1f, stroke.optDouble("width", 0.004).toFloat() * area.width())
            val path = Path()
            var first = true
            var i = 0
            while (i + 1 < points.length()) {
                val x = area.left + points.optDouble(i).toFloat() * area.width()
                val y = area.top + points.optDouble(i + 1).toFloat() * area.height()
                if (first) path.moveTo(x, y) else path.lineTo(x, y)
                first = false
                i += 2
            }
            if (points.length() == 2) path.lineTo(area.left + points.optDouble(0).toFloat() * area.width() + 0.1f,
                area.top + points.optDouble(1).toFloat() * area.height())
            canvas.drawPath(path, paint)
        }
    }

    private fun key(year: Int, month: Int, day: Int) = String.format(Locale.ROOT, "%04d-%02d-%02d", year, month, day)

    fun calendar(payload: JSONObject?, width: Int, height: Int, dp: Float, today: Calendar): Bitmap {
        val bitmap = Bitmap.createBitmap(max(1, width), max(1, height), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        background(canvas, width, height, dp)
        val year = today.get(Calendar.YEAR)
        val month = today.get(Calendar.MONTH) + 1
        val todayKey = key(year, month, today.get(Calendar.DAY_OF_MONTH))
        val pad = 10 * dp
        val title = text(15 * dp, INK, bold = true)
        canvas.drawText("${year}년 ${month}월", pad, pad + 15 * dp, title)

        val weekdays = arrayOf("일", "월", "화", "수", "목", "금", "토")
        val gridLeft = pad
        val gridRight = width - pad
        val columnWidth = (gridRight - gridLeft) / 7f
        val weekdayTop = pad + 24 * dp
        val weekdayPaint = text(10 * dp, GREY)
        for (column in 0 until 7) {
            weekdayPaint.color = when (column) { 0 -> SUNDAY; 6 -> SATURDAY; else -> GREY }
            val label = weekdays[column]
            canvas.drawText(label, gridLeft + column * columnWidth + (columnWidth - weekdayPaint.measureText(label)) / 2,
                weekdayTop + 10 * dp, weekdayPaint)
        }

        val first = Calendar.getInstance().apply {
            clear()
            set(year, month - 1, 1)
        }
        val offset = first.get(Calendar.DAY_OF_WEEK) - Calendar.SUNDAY
        val days = first.getActualMaximum(Calendar.DAY_OF_MONTH)
        val rows = ceil((offset + days) / 7.0).toInt()
        val gridTop = weekdayTop + 16 * dp
        val grid = RectF(gridLeft, gridTop, gridRight, height - pad)
        val rowHeight = grid.height() / rows

        // Every date shown in the grid, row by row (adjacent months included, drawn faint).
        val cell = Calendar.getInstance().apply {
            clear()
            set(year, month - 1, 1)
            add(Calendar.DAY_OF_MONTH, -offset)
        }
        val dates = Array(rows * 7) {
            val entry = Triple(cell.get(Calendar.YEAR), cell.get(Calendar.MONTH) + 1, cell.get(Calendar.DAY_OF_MONTH))
            cell.add(Calendar.DAY_OF_MONTH, 1)
            entry
        }
        val keys = dates.map { (y, m, d) -> key(y, m, d) }

        val linePaint = Paint().apply { color = LINE; strokeWidth = max(1f, dp * 0.7f) }
        for (row in 1 until rows) canvas.drawLine(grid.left, grid.top + row * rowHeight, grid.right, grid.top + row * rowHeight, linePaint)

        val numberPaint = text(10.5f * dp, INK)
        val numberHeight = 15 * dp
        val lineHeight = 11.5f * dp
        val eventPaint = text(8.5f * dp, INK)
        val events = payload?.optJSONArray("events") ?: JSONArray()

        for (row in 0 until rows) {
            val top = grid.top + row * rowHeight
            val capacity = max(0, ((rowHeight - numberHeight - 2 * dp) / lineHeight).toInt())
            val used = Array(7) { 0 }
            val overflow = Array(7) { 0 }
            // Multi-day events first, as bars across the days they cover in this week.
            val lanes = mutableListOf<BooleanArray>()
            for (index in 0 until events.length()) {
                val event = events.optJSONObject(index) ?: continue
                val start = event.optString("start")
                val end = event.optString("end", start)
                if (start.isEmpty() || end <= start) continue
                val columns = (0 until 7).filter { keys[row * 7 + it] in start..end }
                if (columns.isEmpty()) continue
                val from = columns.first()
                val to = columns.last()
                var lane = lanes.indexOfFirst { taken -> (from..to).none { taken[it] } }
                if (lane < 0) {
                    lanes.add(BooleanArray(7))
                    lane = lanes.size - 1
                }
                for (column in from..to) lanes[lane][column] = true
                if (lane >= capacity) {
                    for (column in from..to) overflow[column]++
                    continue
                }
                val barTop = top + numberHeight + lane * lineHeight
                val barColor = color(event.optString("color"), ACCENT)
                val bar = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = barColor; alpha = 70 }
                val rect = RectF(grid.left + from * columnWidth + dp, barTop, grid.left + (to + 1) * columnWidth - dp,
                    barTop + lineHeight - 1.5f * dp)
                canvas.drawRoundRect(rect, 2 * dp, 2 * dp, bar)
                canvas.drawText(fit(event.optString("title"), eventPaint, rect.width() - 4 * dp), rect.left + 2 * dp,
                    rect.bottom - 2.5f * dp, eventPaint)
                for (column in from..to) used[column] = max(used[column], lane + 1)
            }
            // One-day events under the bars, each with a colour mark on its left.
            for (column in 0 until 7) {
                val dayKey = keys[row * 7 + column]
                var line = used[column]
                for (index in 0 until events.length()) {
                    val event = events.optJSONObject(index) ?: continue
                    val start = event.optString("start")
                    val end = event.optString("end", start)
                    if (start != dayKey || end > start) continue
                    if (line >= capacity) {
                        overflow[column]++
                        continue
                    }
                    val y = top + numberHeight + line * lineHeight
                    val left = grid.left + column * columnWidth + 2 * dp
                    val mark = Paint().apply { color = color(event.optString("color"), ACCENT) }
                    canvas.drawRect(left, y + 1 * dp, left + 2 * dp, y + lineHeight - 2 * dp, mark)
                    canvas.drawText(fit(event.optString("title"), eventPaint, columnWidth - 7 * dp), left + 4 * dp,
                        y + lineHeight - 3 * dp, eventPaint)
                    line++
                }
            }
            for (column in 0 until 7) {
                val (_, m, d) = dates[row * 7 + column]
                val left = grid.left + column * columnWidth
                val label = d.toString()
                val labelWidth = numberPaint.measureText(label)
                val x = left + (columnWidth - labelWidth) / 2
                val baseline = top + 11.5f * dp
                if (keys[row * 7 + column] == todayKey) {
                    val badge = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = INK }
                    val size = max(labelWidth + 6 * dp, 15 * dp)
                    canvas.drawRoundRect(RectF(left + (columnWidth - size) / 2, top + 1 * dp,
                        left + (columnWidth + size) / 2, top + 1 * dp + 14 * dp), 4 * dp, 4 * dp, badge)
                    numberPaint.color = Color.WHITE
                } else {
                    numberPaint.color = when {
                        m != month -> FAINT
                        column == 0 -> SUNDAY
                        column == 6 -> SATURDAY
                        else -> INK
                    }
                }
                canvas.drawText(label, x, baseline, numberPaint)
                if (overflow[column] > 0) {
                    val more = text(8 * dp, GREY)
                    val note = "+${overflow[column]}"
                    canvas.drawText(note, left + columnWidth - more.measureText(note) - 2 * dp, top + rowHeight - 2 * dp, more)
                }
            }
        }
        val monthKey = String.format(Locale.ROOT, "%04d-%02d", year, month)
        strokes(canvas, payload?.optJSONObject("months")?.optJSONObject(monthKey)?.optJSONArray("strokes"), grid)
        return bitmap
    }

    /** A repeating reminder shows its next time, not a past one in red. */
    private fun shownAt(item: JSONObject, now: Long): Long? =
        if (item.isNull("at")) null else ReminderAlarms.nextAt(item.optLong("at"), item.optInt("step"), now)

    fun reminders(payload: JSONObject?, width: Int, height: Int, dp: Float, now: Long): Bitmap {
        val bitmap = Bitmap.createBitmap(max(1, width), max(1, height), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        background(canvas, width, height, dp)
        val pad = 12 * dp
        val items = mutableListOf<JSONObject>()
        val list = payload?.optJSONArray("items") ?: JSONArray()
        for (index in 0 until list.length()) {
            val item = list.optJSONObject(index) ?: continue
            if (!item.optBoolean("done")) items.add(item)
        }
        items.sortWith(compareBy({ shownAt(it, now) ?: Long.MAX_VALUE }, { it.optInt("order") }))
        val title = text(15 * dp, INK, bold = true)
        canvas.drawText("리마인더", pad, pad + 15 * dp, title)
        if (items.isNotEmpty()) {
            val count = text(12 * dp, GREY)
            val label = items.size.toString()
            canvas.drawText(label, width - pad - count.measureText(label), pad + 15 * dp, count)
        }
        var y = pad + 26 * dp
        val memo = payload?.optJSONObject("memo")
        val memoStrokes = memo?.optJSONArray("strokes")
        if (memoStrokes != null && memoStrokes.length() > 0) {
            val aspect = memo.optDouble("aspect", 2.0).toFloat().coerceIn(0.5f, 6f)
            val memoWidth = width - 2 * pad
            val memoHeight = min(memoWidth / aspect, (height - y - pad) * 0.45f)
            val area = RectF(pad, y, pad + memoWidth, y + memoHeight)
            canvas.drawRoundRect(area, 10 * dp, 10 * dp, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = MEMO })
            strokes(canvas, memoStrokes, area)
            y += memoHeight + 8 * dp
        }
        val itemPaint = text(12.5f * dp, INK)
        val timePaint = text(11 * dp, GREY)
        val rowHeight = 24 * dp
        val circle = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * dp
            color = GREY
        }
        if (items.isEmpty()) {
            val empty = text(12 * dp, GREY)
            canvas.drawText("할 일이 없습니다", pad, y + 16 * dp, empty)
            return bitmap
        }
        val fits = max(1, ((height - y - pad) / rowHeight).toInt())
        val shown = if (items.size > fits) fits - 1 else items.size
        for (index in 0 until max(0, shown)) {
            val item = items[index]
            val center = y + rowHeight / 2
            canvas.drawCircle(pad + 7 * dp, center, 6.5f * dp, circle)
            val at = shownAt(item, now)
            var timeWidth = 0f
            if (at != null) {
                val label = timeLabel(at, now)
                timePaint.color = if (at < now) SUNDAY else GREY
                timeWidth = timePaint.measureText(label)
                canvas.drawText(label, width - pad - timeWidth, center + 4 * dp, timePaint)
            }
            val textLeft = pad + 20 * dp
            canvas.drawText(fit(item.optString("text"), itemPaint, width - pad - textLeft - timeWidth - 6 * dp),
                textLeft, center + 4.5f * dp, itemPaint)
            y += rowHeight
        }
        if (shown < items.size) {
            canvas.drawText("+${items.size - shown}개 더", pad + 20 * dp, y + 15 * dp, timePaint.apply { color = GREY })
        }
        return bitmap
    }

    private fun timeLabel(at: Long, now: Long): String {
        val time = Calendar.getInstance().apply { timeInMillis = at }
        val today = Calendar.getInstance().apply { timeInMillis = now }
        val clock = String.format(Locale.ROOT, "%02d:%02d", time.get(Calendar.HOUR_OF_DAY), time.get(Calendar.MINUTE))
        val sameDay = time.get(Calendar.YEAR) == today.get(Calendar.YEAR) &&
            time.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)
        return if (sameDay) "오늘 $clock" else "${time.get(Calendar.MONTH) + 1}/${time.get(Calendar.DAY_OF_MONTH)} $clock"
    }
}

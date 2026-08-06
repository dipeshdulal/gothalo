package com.dipeshdulal.gothalo

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The home-screen widget: "does anything need me?" at a glance.
 *
 * It is a pure renderer. Every number it shows was written by Dart into the
 * shared widget store (see `fleet_widget_store.dart` and
 * `docs/CONTRACT-android-widget.md`); this class never talks to a bridge, never
 * schedules work, and `updatePeriodMillis` is 0 — so the widget costs a phone
 * nothing between the app being open and a push arriving.
 */
class FleetWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val needsYou = widgetData.getInt(KEY_NEEDS_YOU, 0)
        val working = widgetData.getInt(KEY_WORKING, 0)
        val done = widgetData.getInt(KEY_DONE, 0)
        val servers = widgetData.getInt(KEY_SERVERS, 0)
        // A string, not a long: see the note on `kKeyUpdatedAt` in
        // `fleet_widget_store.dart` — the channel's int widening makes the
        // stored type depend on the value.
        val updatedAt = widgetData.getString(KEY_UPDATED_AT, null)?.toLongOrNull() ?: 0L
        val lines =
            widgetData.getString(KEY_LINES, "")
                .orEmpty()
                .split("\n")
                .filter { it.isNotBlank() }

        appWidgetIds.forEach { widgetId ->
            val views =
                RemoteViews(context.packageName, R.layout.fleet_widget).apply {
                    setTextViewText(R.id.fleet_needs_you, needsYou.toString())
                    setTextViewText(R.id.fleet_working, working.toString())
                    setTextViewText(R.id.fleet_done, done.toString())

                    // A blocked agent is the only thing on here that is actually
                    // asking for something, so it is the only thing that gets the
                    // alarm colour — and only when there is one.
                    setTextColor(
                        R.id.fleet_needs_you,
                        context.getColor(
                            if (needsYou > 0) R.color.fleet_alert else R.color.fleet_number
                        ),
                    )

                    setTextViewText(R.id.fleet_age, ageLabel(servers, updatedAt))
                    bindLines(context, servers, needsYou, done, lines)

                    // Tapping anywhere opens Priority — the in-app screen that
                    // answers the same question in full.
                    setOnClickPendingIntent(
                        R.id.fleet_root,
                        HomeWidgetLaunchIntent.getActivity(
                            context,
                            MainActivity::class.java,
                            Uri.parse(TAP_URI),
                        ),
                    )
                }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /**
     * The three body rows: the agents that want you, or the one sentence that
     * explains why there are none.
     *
     * "Nothing needs you" and "this phone is not paired with anything" are the
     * same numbers and opposite meanings, so they must never read the same.
     */
    private fun RemoteViews.bindLines(
        context: Context,
        servers: Int,
        needsYou: Int,
        done: Int,
        lines: List<String>,
    ) {
        val rows = intArrayOf(R.id.fleet_line_1, R.id.fleet_line_2, R.id.fleet_line_3)
        val message =
            when {
                servers == 0 -> context.getString(R.string.fleet_widget_unpaired)
                lines.isEmpty() && needsYou == 0 && done == 0 ->
                    context.getString(R.string.fleet_widget_all_clear)
                lines.isEmpty() -> context.getString(R.string.fleet_widget_no_detail)
                else -> null
            }

        if (message != null) {
            setTextViewText(rows[0], message)
            setViewVisibility(rows[0], View.VISIBLE)
            setTextColor(rows[0], context.getColor(R.color.fleet_muted))
            for (i in 1 until rows.size) setViewVisibility(rows[i], View.GONE)
            return
        }

        rows.forEachIndexed { i, id ->
            if (i < lines.size) {
                setTextViewText(id, lines[i])
                setTextColor(id, context.getColor(R.color.fleet_line))
                setViewVisibility(id, View.VISIBLE)
            } else {
                setViewVisibility(id, View.GONE)
            }
        }
    }

    /**
     * How old the freshest number on the widget is.
     *
     * Shown because the widget cannot refresh itself: everything on it dates
     * from the last time the app was open or a push arrived, and a stale count
     * that looks live is worse than no count. `now` beyond a day is not worth a
     * unit of its own — at that point the answer is "open the app".
     */
    private fun ageLabel(servers: Int, updatedAt: Long): String {
        if (servers == 0 || updatedAt <= 0L) return ""
        val seconds = (System.currentTimeMillis() - updatedAt) / 1000
        return when {
            seconds < 0 -> ""
            seconds < 60 -> "now"
            seconds < 3600 -> "${seconds / 60}m"
            seconds < 86_400 -> "${seconds / 3600}h"
            else -> "old"
        }
    }

    private companion object {
        // Mirrors `fleet_widget_store.dart`. Changing either side alone makes a
        // value silently render as its default.
        const val KEY_NEEDS_YOU = "fleet.needs_you"
        const val KEY_WORKING = "fleet.working"
        const val KEY_DONE = "fleet.done"
        const val KEY_SERVERS = "fleet.servers"
        const val KEY_LINES = "fleet.lines"
        const val KEY_UPDATED_AT = "fleet.updated_at"

        const val TAP_URI = "gothalo://widget/priority"
    }
}

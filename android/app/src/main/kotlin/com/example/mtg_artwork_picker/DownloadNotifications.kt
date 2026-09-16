package com.example.mtg_artwork_picker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Posts the artwork-download progress notification.
 *
 * flutter_foreground_task exposes no progress-bar API (none of its versions
 * do), so the bar is built here and posted under the foreground service's own
 * notification id and channel. Reusing the id means the post *replaces* the
 * service's "Downloading Artworks" entry instead of adding a second
 * notification beside it, and stopping the service clears it again — that is
 * the same `NotificationManager.notify(serviceId, ...)` call the plugin itself
 * uses to refresh its notification.
 *
 * [PROGRESS_ID] must stay equal to the `serviceId` passed to
 * FlutterForegroundTask.startService and [CHANNEL_ID] equal to its channelId,
 * both set in lib/core/foreground_download_service.dart.
 */
class DownloadNotifications(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "proxystant/download_notifications"
        private const val CHANNEL_ID = "mtg_download_channel"
        private const val PROGRESS_ID = 256
        private const val FINISHED_ID = 257
        private const val TAG = "DownloadNotifications"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "showProgress" -> {
                    val total = call.argument<Int>("total") ?: 0
                    post(
                        id = PROGRESS_ID,
                        notification = build(
                            title = call.argument<String>("title") ?: "",
                            text = call.argument<String>("text") ?: "",
                            subText = call.argument<String>("subText"),
                            progressMax = total,
                            progress = call.argument<Int>("processed") ?: 0,
                            // No total yet (the run is still counting cards):
                            // show a cycling bar rather than an empty one.
                            indeterminate = total <= 0,
                            ongoing = true,
                        ),
                    )
                    result.success(null)
                }

                "showFinished" -> {
                    post(
                        id = FINISHED_ID,
                        notification = build(
                            title = call.argument<String>("title") ?: "",
                            text = call.argument<String>("text") ?: "",
                            subText = null,
                            progressMax = 0,
                            progress = 0,
                            indeterminate = false,
                            ongoing = false,
                        ),
                    )
                    result.success(null)
                }

                "cancel" -> {
                    manager().cancel(PROGRESS_ID)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Never fail the download over a notification.
            Log.e(TAG, "onMethodCall(${call.method})", e)
            result.error("notification_failed", e.message, null)
        }
    }

    private fun manager(): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun post(id: Int, notification: Notification) {
        val nm = manager()
        ensureChannel(nm)
        nm.notify(id, notification)
    }

    /**
     * The channel normally already exists — the foreground service creates it
     * when it starts. It is recreated here for the completion notification,
     * which can outlive the service.
     */
    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Artwork Download",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Runs while artworks are being downloaded."
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    @Suppress("DEPRECATION")
    private fun build(
        title: String,
        text: String,
        subText: String?,
        progressMax: Int,
        progress: Int,
        indeterminate: Boolean,
        ongoing: Boolean,
    ): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

        builder.setSmallIcon(appIconResId())
        builder.setContentTitle(title)
        builder.setContentText(text)
        builder.setShowWhen(false)
        // Without this every progress refresh re-alerts (heads-up / sound).
        builder.setOnlyAlertOnce(true)
        builder.setOngoing(ongoing)
        builder.setAutoCancel(!ongoing)
        contentIntent()?.let(builder::setContentIntent)
        if (subText != null) builder.setSubText(subText)
        if (indeterminate || progressMax > 0) {
            builder.setProgress(progressMax, progress, indeterminate)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_LOW)
            builder.setSound(null)
        }
        if (ongoing && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build()
    }

    /**
     * Resolved the same way flutter_foreground_task resolves its own icon, so
     * replacing its notification doesn't change the icon mid-run.
     */
    private fun appIconResId(): Int = try {
        context.packageManager
            .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            .icon
    } catch (e: Exception) {
        Log.e(TAG, "appIconResId()", e)
        0
    }

    private fun contentIntent(): PendingIntent? {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, 0, launch, flags)
    }
}

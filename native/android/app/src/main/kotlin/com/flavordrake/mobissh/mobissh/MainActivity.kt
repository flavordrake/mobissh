package com.flavordrake.mobissh.mobissh

import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * MobiSSH Flutter host activity.
 *
 * Installs a JVM-level uncaught exception handler the moment the engine is
 * configured so that crashes happening before the Dart side has booted (e.g.
 * plugin init failures — the very class of crash that motivated #501) still
 * land in a JSON file the Dart-side crash reporter can later upload to the
 * bridge.
 *
 * The on-disk format intentionally mirrors what `crash_reporter.dart` writes
 * so both kinds of crash flow through one upload path.
 *
 * Crashes are written into `filesDir/app_flutter/crashes/<ts>.json`, because
 * Flutter's `path_provider` package returns `filesDir/app_flutter` from
 * `getApplicationDocumentsDirectory()`. Keeping both producers in the same
 * directory means uploadPending() can sweep both with a single readDir.
 */
class MainActivity : FlutterActivity() {
    private val tag = "MobiSSHCrash"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installNativeCrashHandler()
    }

    private fun installNativeCrashHandler() {
        try {
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                try {
                    writeCrashFile(thread, throwable)
                } catch (writeErr: Throwable) {
                    Log.e(tag, "failed to persist crash", writeErr)
                }
                // Chain to the previous handler so the OS still records the
                // crash in logcat and shows the "App keeps stopping" dialog.
                previous?.uncaughtException(thread, throwable)
            }
            Log.i(tag, "native uncaught-exception handler installed")
        } catch (err: Throwable) {
            // Crash reporter must never crash. Swallow and log.
            Log.e(tag, "failed to install crash handler", err)
        }
    }

    private fun writeCrashFile(thread: Thread, throwable: Throwable) {
        val docs = File(applicationContext.filesDir, "app_flutter/crashes")
        if (!docs.exists()) {
            docs.mkdirs()
        }

        val stamp = compactStamp()
        val outFile = File(docs, "$stamp-native.json")

        val stackWriter = StringWriter()
        throwable.printStackTrace(PrintWriter(stackWriter))

        val sb = StringBuilder()
        sb.append('{')
        appendStringField(sb, "schema", "1", true, raw = true)
        appendStringField(sb, "kind", "native")
        appendStringField(sb, "ts", isoNow())
        appendStringField(sb, "appVersion", appVersionString())
        appendStringField(sb, "buildSha", buildShaString())
        appendStringField(
            sb,
            "platformVersion",
            "Android ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})"
        )
        appendStringField(sb, "deviceModel", "${Build.MANUFACTURER} ${Build.MODEL}")
        appendStringField(sb, "error", throwable.toString())
        appendStringField(sb, "errorType", throwable.javaClass.name)
        appendStringField(sb, "stack", stackWriter.toString())
        appendStringField(sb, "threadName", thread.name ?: "")
        appendStringField(sb, "context", "android-uncaught")
        sb.append('}')

        outFile.writeText(sb.toString(), Charsets.UTF_8)
        Log.w(tag, "native crash recorded: ${outFile.absolutePath}")
    }

    private fun appendStringField(
        sb: StringBuilder,
        key: String,
        value: String,
        first: Boolean = false,
        raw: Boolean = false,
    ) {
        if (!first) sb.append(',')
        sb.append('"').append(escapeJson(key)).append('"').append(':')
        if (raw) {
            sb.append(value)
        } else {
            sb.append('"').append(escapeJson(value)).append('"')
        }
    }

    private fun escapeJson(s: String): String {
        val sb = StringBuilder(s.length + 8)
        for (c in s) {
            when {
                c == '\\' -> sb.append("\\\\")
                c == '"' -> sb.append("\\\"")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c.code == 0x08 -> sb.append("\\b")
                c.code == 0x0C -> sb.append("\\f")
                c.code < 0x20 ->
                    sb.append(String.format(Locale.US, "\\u%04x", c.code))
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }

    private fun compactStamp(): String {
        val fmt = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    private fun isoNow(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    private fun appVersionString(): String {
        return try {
            val info = packageManager.getPackageInfo(packageName, 0)
            "${info.versionName ?: ""}+${info.longVersionCode}"
        } catch (err: Throwable) {
            ""
        }
    }

    private fun buildShaString(): String {
        // Flutter doesn't ship a built-in git sha on Android; the pubspec
        // version + build number is the most reliable build identifier and is
        // already in appVersion. Leave a marker so the schema is uniform.
        return "android-${Build.VERSION.SDK_INT}"
    }
}

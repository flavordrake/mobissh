package com.flavordrake.mobissh.mobissh

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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

    // ── Storage Access Framework file picker (#529 — custom MethodChannel
    // bypass of the broken `file_picker` package). The bridge between Dart's
    // `MethodChannelFilePickerAdapter` and Android's `ACTION_OPEN_DOCUMENT`
    // intent. Result holds the pending MethodChannel result so
    // `onActivityResult` can complete it asynchronously.
    private var pendingPickerResult: MethodChannel.Result? = null
    private val pickerChannel = "mobissh/storage_picker"
    private val pickerRequestCode = 0xC0DE

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installNativeCrashHandler()
        installStoragePickerChannel(flutterEngine)
    }

    private fun installStoragePickerChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            pickerChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickJsonBytes" -> {
                    if (pendingPickerResult != null) {
                        result.error("ALREADY_OPEN", "picker already in flight", null)
                        return@setMethodCallHandler
                    }
                    pendingPickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        // Multiple MIME types because the SAF mime filter is
                        // strict — "application/json" alone hides files the
                        // PWA names with .json that Android stamps with the
                        // generic "application/octet-stream" mime.
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf("application/json", "text/plain", "application/octet-stream"),
                        )
                    }
                    try {
                        startActivityForResult(intent, pickerRequestCode)
                    } catch (err: Throwable) {
                        pendingPickerResult = null
                        result.error(
                            "NO_PICKER",
                            "Storage picker unavailable: ${err.message}",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickerRequestCode) {
            val pending = pendingPickerResult
            pendingPickerResult = null
            if (resultCode != Activity.RESULT_OK || data == null) {
                pending?.success(null) // user cancelled
                return
            }
            val uri: Uri? = data.data
            if (uri == null) {
                pending?.success(null)
                return
            }
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes == null) {
                    pending?.error("READ_FAILED", "Could not read picked URI", uri.toString())
                    return
                }
                val name = displayNameFor(uri) ?: "backup.json"
                pending?.success(mapOf("name" to name, "bytes" to bytes))
            } catch (err: Throwable) {
                pending?.error("READ_FAILED", err.message, uri.toString())
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** Resolve a human-friendly display name for a content URI. SAF returns
     *  `content://` URIs whose path is opaque; the OpenableColumns query is
     *  the documented way to recover the original filename. */
    private fun displayNameFor(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (err: Throwable) {
            Log.w(tag, "displayNameFor failed", err)
            null
        }
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

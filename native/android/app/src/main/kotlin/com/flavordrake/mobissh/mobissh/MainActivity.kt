package com.flavordrake.mobissh.mobissh

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
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

    // ── Hardened clipboard write (#845). Flutter's `Clipboard.setData` builds a
    // `ClipData` with an EMPTY label, which doesn't reliably reach Gboard's
    // clipboard HISTORY. This channel writes a LABELED plain-text clip so the
    // copy surfaces in history immediately (not "empty-until-tapped").
    private val clipboardChannel = "mobissh/clipboard"

    // ── Public Downloads publisher (#559). SFTP downloads stream to an
    // app-private staging file (offset-honoring reassembly); this channel
    // copies the finished file into the user-visible shared Downloads
    // collection so it lands where the system file manager / "Downloads"
    // shows it. API 29+ uses MediaStore (scoped storage, no permission);
    // older devices fall back to the public Downloads dir behind the legacy
    // WRITE_EXTERNAL_STORAGE perm (declared maxSdkVersion=28 in the manifest).
    private val downloadsChannel = "mobissh/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installNativeCrashHandler()
        installStoragePickerChannel(flutterEngine)
        installClipboardChannel(flutterEngine)
        installDownloadsChannel(flutterEngine)
    }

    private fun installDownloadsChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadsChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publishToDownloads" -> {
                    val srcPath = call.argument<String>("srcPath")
                    val fileName = call.argument<String>("fileName")
                    val mimeArg = call.argument<String>("mimeType")
                    if (srcPath.isNullOrEmpty() || fileName.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "srcPath and fileName required", null)
                        return@setMethodCallHandler
                    }
                    // Copy off the UI thread — files can be large. Complete the
                    // MethodChannel result back on the UI thread.
                    Thread {
                        try {
                            val location = publishToDownloads(srcPath, fileName, mimeArg)
                            runOnUiThread { result.success(location) }
                        } catch (err: Throwable) {
                            Log.w(tag, "publishToDownloads failed", err)
                            runOnUiThread {
                                result.error("PUBLISH_FAILED", err.message, null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Copy [srcPath] into the user-visible Downloads collection under
     *  [fileName]. Returns a human-readable location ("Downloads/<name>").
     *  Throws on failure so the caller can fall back to the staging path. */
    private fun publishToDownloads(srcPath: String, fileName: String, mimeType: String?): String {
        val src = File(srcPath)
        if (!src.exists()) throw IllegalStateException("staging file missing: $srcPath")
        val mime = mimeType ?: guessMimeType(fileName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            publishViaMediaStore(src, fileName, mime)
        } else {
            publishViaLegacyDir(src, fileName)
        }
    }

    private fun publishViaMediaStore(src: File, fileName: String, mime: String): String {
        val resolver = contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert returned null")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("openOutputStream returned null")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (err: Throwable) {
            // Roll back the half-written pending entry so it doesn't linger.
            try {
                resolver.delete(uri, null, null)
            } catch (_: Throwable) {
            }
            throw err
        }
        // MediaStore resolves DISPLAY_NAME collisions itself ("name (1).ext").
        val saved = displayNameFor(uri) ?: fileName
        return "Downloads/$saved"
    }

    private fun publishViaLegacyDir(src: File, fileName: String): String {
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!dir.exists()) dir.mkdirs()
        var dest = File(dir, fileName)
        // Avoid clobbering an existing file: append " (n)" before the extension.
        if (dest.exists()) {
            val dot = fileName.lastIndexOf('.')
            val stem = if (dot > 0) fileName.substring(0, dot) else fileName
            val ext = if (dot > 0) fileName.substring(dot) else ""
            var n = 1
            while (dest.exists()) {
                dest = File(dir, "$stem ($n)$ext")
                n++
            }
        }
        FileInputStream(src).use { input ->
            FileOutputStream(dest).use { out -> input.copyTo(out) }
        }
        return "Downloads/${dest.name}"
    }

    private fun guessMimeType(fileName: String): String {
        val ext = MimeTypeMap.getFileExtensionFromUrl(fileName)?.lowercase(java.util.Locale.US)
        val fromMap = if (!ext.isNullOrEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        } else {
            null
        }
        return fromMap ?: "application/octet-stream"
    }

    private fun installClipboardChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            clipboardChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setText" -> {
                    val text = call.argument<String>("text")
                    val label = call.argument<String>("label") ?: "MobiSSH"
                    if (text.isNullOrEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    // MethodChannel handlers already run on the platform (UI)
                    // thread; post anyway to be explicit about the requirement.
                    runOnUiThread {
                        try {
                            val clip = ClipData.newPlainText(label, text)
                            // #924 — On Android 13+ (API 33) a clip with no
                            // explicit sensitivity flag can be treated/surfaced
                            // oddly (preview suppression, redacted history),
                            // which matched "appears correct but won't paste".
                            // A URL/path is not a secret, so mark it explicitly
                            // NON-sensitive so the system propagates it for
                            // normal cross-app paste.
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                clip.description.extras = android.os.PersistableBundle().apply {
                                    putBoolean(
                                        ClipDescription.EXTRA_IS_SENSITIVE,
                                        false,
                                    )
                                }
                            }
                            // Resolve the ClipboardManager from the foreground
                            // activity context (this Activity), not
                            // applicationContext — the system surfaces the
                            // primary clip for the focused activity's manager.
                            val manager = getSystemService(Context.CLIPBOARD_SERVICE)
                                as ClipboardManager
                            manager.setPrimaryClip(clip)
                            // #962 instrumentation: read back from the SAME
                            // manager immediately so a device repro shows exactly
                            // what the system holds — does a primary clip exist,
                            // does its text match, is it flagged sensitive, and
                            // did the activity have WINDOW FOCUS at write time
                            // (Android gates cross-app clip propagation on the
                            // writer being the focused foreground app).
                            val back = manager.primaryClip?.let { pc ->
                                if (pc.itemCount > 0) {
                                    pc.getItemAt(0)
                                        .coerceToText(this@MainActivity)?.toString()
                                } else {
                                    null
                                }
                            }
                            val sensitiveBack =
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                    manager.primaryClipDescription?.extras
                                        ?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE)
                                } else {
                                    null
                                }
                            result.success(
                                mapOf(
                                    "ok" to true,
                                    "sdk" to Build.VERSION.SDK_INT,
                                    "release" to Build.VERSION.RELEASE,
                                    "model" to Build.MODEL,
                                    "wroteLen" to text.length,
                                    "hasPrimaryClip" to manager.hasPrimaryClip(),
                                    "readbackLen" to (back?.length ?: -1),
                                    "matches" to (back == text),
                                    "sensitiveReadback" to sensitiveBack,
                                    "windowFocus" to hasWindowFocus(),
                                ),
                            )
                        } catch (err: Throwable) {
                            result.error("CLIPBOARD_FAILED", err.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
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

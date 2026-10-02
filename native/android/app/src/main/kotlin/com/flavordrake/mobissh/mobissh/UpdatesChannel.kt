package com.flavordrake.mobissh.mobissh

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Self-update, native half (#1216, spec docs/self-update.md R9-R11, R13).
 * Dart (services/self_update.dart) downloads the APK and checks its sha256
 * against the manifest; that only proves "the host served this". This class is
 * the security line (D4): it refuses the file unless its package name AND its
 * signing-certificate set equal the running app's (R10), and only then hands
 * it to the system installer (R11). Verify and hand-off are ONE method, so
 * nothing can hand off an unverified file.
 *
 * Contract (method names, argument and result keys) mirrors the Dart side.
 */
class UpdatesChannel(private val activity: Activity) {
    private val tag = "MobiSSHUpdate"
    private val main = Handler(Looper.getMainLooper())
    private val pkg: String get() = activity.packageName
    private val authority: String get() = "$pkg.updates.fileprovider"
    private val apkMime = "application/vnd.android.package-archive"

    fun install(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobissh/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "isUnmetered" -> result.success(isUnmetered())
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "verifyAndInstall" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.success(reply("error", "path required"))
                            return@setMethodCallHandler
                        }
                        // Parsing + signature-verifying a ~30MB APK is disk and
                        // CPU work: off the UI thread, then back for the launch.
                        Thread {
                            val verdict = try {
                                verify(path)
                            } catch (err: Throwable) {
                                Log.w(tag, "verify failed", err)
                                Verdict.refuse("could not verify: ${err.message}")
                            }
                            main.post {
                                result.success(
                                    try {
                                        finish(path, verdict)
                                    } catch (err: Throwable) {
                                        Log.w(tag, "hand-off failed", err)
                                        deleteQuietly(path)
                                        reply("error", "${err.message}")
                                    }
                                )
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * R13: the updater exists only when the MERGED manifest carries both the
     * provider and the permission — true for the sideload APK, false for the
     * Play bundle (src/play/AndroidManifest.xml removes both). Dart shows no
     * update UI when false. R9: the device's primary ABI.
     */
    @Suppress("DEPRECATION")
    private fun capabilities(): Map<String, Any?> {
        val pm = activity.packageManager
        val supported = try {
            val info = pm.getPackageInfo(
                pkg,
                PackageManager.GET_PROVIDERS or PackageManager.GET_PERMISSIONS,
            )
            val hasProvider = info.providers?.any { it.authority == authority } == true
            val hasPermission = info.requestedPermissions
                ?.contains(Manifest.permission.REQUEST_INSTALL_PACKAGES) == true
            hasProvider && hasPermission
        } catch (err: Throwable) {
            Log.w(tag, "capabilities failed", err)
            false
        }
        return mapOf(
            "supported" to supported,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        )
    }

    /**
     * #1258 R14: pre-download only on an unmetered network (Wi-Fi). Platform
     * info, so no connectivity plugin. Unknown → metered (no pre-download).
     */
    private fun isUnmetered(): Boolean {
        return try {
            val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE)
            (cm as ConnectivityManager).isActiveNetworkMetered.not()
        } catch (err: Throwable) {
            Log.w(tag, "isUnmetered failed", err)
            false
        }
    }

    /** #1258 R15: "install unknown apps" is granted (always true before O). */
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()

    private class Verdict(val accepted: Boolean, val reason: String) {
        companion object {
            fun refuse(reason: String) = Verdict(false, reason)
            val ok = Verdict(true, "")
        }
    }

    /** The file must live in cache/updates/ — never delete or hand off anything else. */
    private fun confined(path: String): File? {
        val root = File(activity.cacheDir, "updates").canonicalFile
        val file = File(path).canonicalFile
        return if (file.parentFile == root) file else null
    }

    /** R10: package name AND signing-certificate set must equal ours. */
    @Suppress("DEPRECATION")
    private fun verify(path: String): Verdict {
        val file = confined(path) ?: return Verdict.refuse("not in the updates directory")
        if (!file.isFile) return Verdict.refuse("downloaded file is missing")
        // GET_SIGNING_CERTIFICATES / SigningInfo are API 28+. Older releases
        // only offer GET_SIGNATURES, which getPackageArchiveInfo does not
        // reliably populate for an archive — so fail CLOSED there.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return Verdict.refuse("self-update needs Android 9 or newer")
        }
        val pm = activity.packageManager
        val archive = pm.getPackageArchiveInfo(
            file.path,
            PackageManager.GET_SIGNING_CERTIFICATES,
        ) ?: return Verdict.refuse("not a readable APK")
        if (archive.packageName != pkg) {
            return Verdict.refuse("package ${archive.packageName} is not $pkg")
        }
        val theirs = signerSet(archive)
            ?: return Verdict.refuse("the APK carries no signing certificate")
        val ours = signerSet(pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES))
            ?: return Verdict.refuse("could not read this app's signing certificate")
        if (theirs != ours) {
            return Verdict.refuse("signing certificate does not match the installed app")
        }
        return Verdict.ok
    }

    /** The CURRENT signers (not rotation history), as a comparable set. */
    private fun signerSet(info: PackageInfo): Set<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val signers: Array<Signature> = info.signingInfo?.apkContentsSigners ?: return null
        if (signers.isEmpty()) return null
        return signers.map { it.toCharsString() }.toSet()
    }

    /** R10 refusal deletes; R11 permission / hand-off otherwise. Main thread. */
    private fun finish(path: String, verdict: Verdict): Map<String, Any?> {
        if (!verdict.accepted) {
            deleteQuietly(path)
            Log.w(tag, "refused: ${verdict.reason}")
            return reply("refused", verdict.reason)
        }
        val file = confined(path) ?: return reply("error", "not in the updates directory")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$pkg"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return reply("needsPermission", "install unknown apps is not allowed")
        }
        val uri = FileProvider.getUriForFile(activity, authority, file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, apkMime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val installer = intent.resolveActivity(activity.packageManager)?.packageName ?: ""
        activity.startActivity(intent)
        Log.i(tag, "handed off ${file.name} to ${installer.ifEmpty { "?" }}")
        return reply("launched", "", installer)
    }

    private fun deleteQuietly(path: String) {
        try {
            confined(path)?.delete()
        } catch (err: Throwable) {
            Log.w(tag, "delete failed", err)
        }
    }

    private fun reply(status: String, reason: String, installer: String = "") =
        mapOf("status" to status, "reason" to reason, "installer" to installer)
}

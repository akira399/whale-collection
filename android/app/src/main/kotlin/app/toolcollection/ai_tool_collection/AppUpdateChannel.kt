package app.toolcollection.ai_tool_collection

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File

internal class AppUpdateChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val packages = activity.packageManager
    private val packageName = activity.packageName
    private val apk get() = File(activity.cacheDir, "updates/whale.apk")

    init {
        MethodChannel(
            messenger,
            "app.toolcollection/updates",
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(
                        mapOf(
                            "version" to packages.getPackageInfo(packageName, 0).versionName,
                            "abis" to Build.SUPPORTED_ABIS.toList(),
                        ),
                    )
                    "verify", "install" -> {
                        if (!verify(call.argument<String>("version"))) {
                            result.error("invalid_apk", "安装包的版本或签名与当前应用不匹配。", null)
                        } else if (call.method == "verify") {
                            result.success(null)
                        } else {
                            activity.runOnUiThread { install(result) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("update_error", "无法检查安装包，请重新下载。", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun verify(version: String?): Boolean {
        if (version == null || !apk.isFile) return false
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val archive = packages.getPackageArchiveInfo(apk.absolutePath, flags) ?: return false
        val installed = packages.getPackageInfo(packageName, flags)
        val signers = archive.signers()
        return archive.packageName == packageName &&
            archive.versionName == version &&
            archive.buildNumber() > installed.buildNumber() &&
            signers.isNotEmpty() && signers == installed.signers()
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.buildNumber(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun PackageInfo.signers() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            signingInfo?.apkContentsSigners.orEmpty().toSet()
        } else {
            signatures.orEmpty().toSet()
        }

    @Suppress("DEPRECATION")
    private fun install(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packages.canRequestPackageInstalls()) {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.fromParts("package", packageName, null)),
                )
                result.success("permission")
                return
            }
            val uri = FileProvider.getUriForFile(activity, "$packageName.updates", apk)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val installer = packages.queryIntentActivities(
                intent,
                PackageManager.MATCH_SYSTEM_ONLY or PackageManager.MATCH_DEFAULT_ONLY,
            ).firstOrNull()?.activityInfo ?: throw ActivityNotFoundException()
            intent.component = ComponentName(installer.packageName, installer.name)
            activity.startActivity(intent)
            result.success("installer")
        } catch (_: Exception) {
            result.error("installer_unavailable", "无法打开系统安装界面。", null)
        }
    }
}

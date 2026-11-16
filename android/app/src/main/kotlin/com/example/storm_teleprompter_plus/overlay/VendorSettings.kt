package com.example.storm_teleprompter_plus.overlay

import android.app.Activity
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import java.util.Locale

/**
 * User-invoked settings shortcuts. OEM pages are best-effort, not permission checks.
 * We never inspect private MIUI AppOps or change any system setting ourselves.
 */
internal class VendorSettings(private val activity: Activity) {
    val isMiuiDevice: Boolean
        get() {
            val xiaomiManufacturer = listOf(Build.MANUFACTURER, Build.BRAND).any {
                it.lowercase(Locale.ROOT) in setOf("xiaomi", "redmi", "poco")
            }
            // Android One / aftermarket AOSP builds can share the same manufacturer.
            // Only expose MIUI-specific guidance when its security center is installed.
            return xiaomiManufacturer && runCatching {
                @Suppress("DEPRECATION")
                activity.packageManager.getApplicationInfo("com.miui.securitycenter", 0)
                true
            }.getOrDefault(false)
        }

    fun status(): Map<String, Any?> = mapOf(
        "isMiuiDevice" to isMiuiDevice,
        "deviceManufacturer" to Build.MANUFACTURER,
        "deviceModel" to Build.MODEL,
        "androidSdk" to Build.VERSION.SDK_INT,
        // This is the standard Android battery exemption only. MIUI's separate
        // background policy and auto-start permission cannot be inferred from it.
        "batteryOptimizationExempt" to runCatching {
            activity.getSystemService(PowerManager::class.java)
                ?.isIgnoringBatteryOptimizations(activity.packageName)
        }.getOrNull(),
    )

    fun notificationsEnabled(): Boolean =
        activity.getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    fun openVendorPermissions() {
        val candidates = mutableListOf<Intent>()
        if (isMiuiDevice) {
            for (name in listOf(
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
                "com.miui.permcenter.permissions.AppPermissionsEditorActivity",
            )) {
                candidates += Intent("miui.intent.action.APP_PERM_EDITOR")
                    .setComponent(ComponentName("com.miui.securitycenter", name))
                    .putExtra("extra_pkgname", activity.packageName)
            }
            candidates += Intent("miui.intent.action.APP_PERM_EDITOR")
                .setPackage("com.miui.securitycenter")
                .putExtra("extra_pkgname", activity.packageName)
        }
        openFirst(candidates + appDetails())
    }

    fun openAutoStartSettings() {
        val candidates = if (isMiuiDevice) listOf(
            Intent().setComponent(ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            )).putExtra("extra_pkgname", activity.packageName),
            Intent().setComponent(ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.selfmanagement.AutoStartManagementActivity",
            )).putExtra("extra_pkgname", activity.packageName),
        ) else emptyList()
        openFirst(candidates + appDetails())
    }

    fun openBatterySettings() {
        val candidates = mutableListOf<Intent>()
        if (isMiuiDevice) {
            candidates += Intent().setComponent(ComponentName(
                "com.miui.powerkeeper",
                "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
            ))
                .putExtra("package_name", activity.packageName)
                .putExtra("package_label", activity.applicationInfo.loadLabel(activity.packageManager).toString())
        }
        candidates += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        openFirst(candidates + appDetails())
    }

    fun openNotificationSettings() {
        val candidates = if (Build.VERSION.SDK_INT >= 26) listOf(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
        ) else emptyList()
        openFirst(candidates + appDetails())
    }

    private fun appDetails() = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.parse("package:${activity.packageName}"),
    )

    private fun openFirst(candidates: List<Intent>) {
        for (intent in candidates + Intent(Settings.ACTION_SETTINGS)) {
            try {
                if (intent.resolveActivity(activity.packageManager) == null) continue
                activity.startActivity(intent)
                return
            } catch (_: Exception) {
                // MIUI activities vary by release and can be protected even when
                // resolvable. Keep the generic application-info fallback usable.
            }
        }
        throw IllegalStateException("无法打开系统设置，请手动进入应用信息配置权限和省电策略。")
    }
}

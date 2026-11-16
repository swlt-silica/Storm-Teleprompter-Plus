package com.example.storm_teleprompter_plus.overlay

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.example.storm_teleprompter_plus.MainActivity

/** The only Android/Flutter entry point. No screen capture or app-content inspection. */
class OverlayBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "storm.teleprompter/overlay")
    private var permissionResult: MethodChannel.Result? = null
    private var permissionRequestCode = 0
    private val vendorSettings = VendorSettings(activity)

    init {
        channel.setMethodCallHandler(this)
        current = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getStatus" -> result.success(mapOf(
                    "overlayPermission" to Settings.canDrawOverlays(activity),
                    "accessibilityEnabled" to (TeleprompterAccessibilityService.current != null),
                    "microphonePermission" to hasPermission(Manifest.permission.RECORD_AUDIO),
                    "notificationPermission" to (vendorSettings.notificationsEnabled() &&
                        (Build.VERSION.SDK_INT < 33 || hasPermission(Manifest.permission.POST_NOTIFICATIONS))),
                    "running" to (TeleprompterOverlayService.current?.isShowing == true),
                ) + vendorSettings.status())
                "requestOverlayPermission" -> {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${activity.packageName}")))
                    result.success(true)
                }
                "openAccessibilitySettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                "openAppSettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
                    result.success(true)
                }
                "openVendorPermissions" -> {
                    vendorSettings.openVendorPermissions()
                    result.success(true)
                }
                "openAutoStartSettings" -> {
                    vendorSettings.openAutoStartSettings()
                    result.success(true)
                }
                "openBatterySettings" -> {
                    vendorSettings.openBatterySettings()
                    result.success(true)
                }
                "requestMicrophonePermission" -> requestPermission(Manifest.permission.RECORD_AUDIO, 8201, result)
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33 && !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
                        requestPermission(Manifest.permission.POST_NOTIFICATIONS, 8202, result)
                    } else if (!vendorSettings.notificationsEnabled()) {
                        vendorSettings.openNotificationSettings()
                        result.success(false)
                    } else result.success(true)
                }
                "start" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    if (!Settings.canDrawOverlays(activity)) {
                        result.error("overlay_permission", "请先允许飓风提词器显示在其他应用上层。", null)
                        return
                    }
                    if (args["mode"] == "asr") {
                        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
                            result.error("microphone_permission", "请先允许麦克风权限，再开启语音悬浮提词。", null)
                            return
                        }
                        if (TeleprompterAccessibilityService.current == null) {
                            result.error("accessibility_permission", "相机语音跟读需要启用“飓风提词器：相机悬浮跟读”无障碍服务。", null)
                            return
                        }
                    }
                    if (TeleprompterOverlayService.current != null) {
                        TeleprompterOverlayService.current!!.update(args)
                        result.success(TeleprompterOverlayService.current?.isShowing == true)
                    } else {
                        if (TeleprompterOverlayService.startResult != null) {
                            result.error("overlay_busy", "悬浮提词正在启动，请稍后重试。", null)
                            return
                        }
                        // The script stays in process memory. An Intent extra can exceed Binder's
                        // transaction limit for a long script, even though this is a local service.
                        val intent = Intent(activity, TeleprompterOverlayService::class.java)
                        TeleprompterOverlayService.pendingPayload = args.toMap()
                        TeleprompterOverlayService.startResult = result
                        if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent)
                        else activity.startService(intent)
                    }
                }
                "update" -> {
                    TeleprompterOverlayService.current?.update(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                    result.success(true)
                }
                "stop" -> {
                    cancelPendingStart()
                    TeleprompterOverlayService.current?.stopByUser(notifyFlutter = false)
                    activity.stopService(Intent(activity, TeleprompterOverlayService::class.java))
                    result.success(true)
                }
                "openCamera" -> {
                    val camera = Intent(MediaStore.INTENT_ACTION_VIDEO_CAMERA)
                    if (camera.resolveActivity(activity.packageManager) == null) {
                        result.error("camera_unavailable", "没有找到可打开的相机，请手动切换到手机相机。", null)
                    } else {
                        activity.startActivity(camera)
                        result.success(true)
                    }
                }
                "returnToApp" -> {
                    if (returnToApp()) result.success(true)
                    else result.error("return_blocked", "无法返回应用，请从桌面或运行通知打开提词器；MIUI 用户请检查“后台弹出界面”权限。", null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (TeleprompterOverlayService.startResult === result) {
                TeleprompterOverlayService.startResult = null
                TeleprompterOverlayService.pendingPayload = null
            }
            result.error("overlay_error", "悬浮提词操作失败：${error.message ?: "请返回应用重试"}", null)
        }
    }

    private fun hasPermission(permission: String) = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(permission: String, code: Int, result: MethodChannel.Result) {
        if (hasPermission(permission)) {
            result.success(true)
        } else if (permissionResult != null) {
            result.error("permission_busy", "请先完成当前权限确认。", null)
        } else {
            permissionResult = result
            permissionRequestCode = code
            activity.requestPermissions(arrayOf(permission), code)
        }
    }

    fun onRequestPermissionsResult(code: Int, grants: IntArray): Boolean {
        if (code != permissionRequestCode || permissionResult == null) return false
        permissionResult?.success(grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED)
        permissionResult = null
        permissionRequestCode = 0
        return true
    }

    private fun emit(action: String, values: Map<String, Any?>) {
        activity.runOnUiThread { channel.invokeMethod("onAction", mapOf("action" to action) + values) }
    }

    fun dispose() {
        permissionResult?.error("activity_closed", "页面已关闭，请重新打开提词器。", null)
        permissionResult = null
        if (current === this) current = null
        channel.setMethodCallHandler(null)
        cancelPendingStart()
        TeleprompterOverlayService.current?.stopByUser(notifyFlutter = false)
        activity.stopService(Intent(activity, TeleprompterOverlayService::class.java))
    }

    private fun cancelPendingStart() {
        TeleprompterOverlayService.pendingPayload = null
        TeleprompterOverlayService.startResult?.error("overlay_cancelled", "悬浮提词启动已取消。", null)
        TeleprompterOverlayService.startResult = null
    }

    companion object {
        private var current: OverlayBridge? = null

        fun action(action: String, values: Map<String, Any?> = emptyMap()) {
            current?.emit(action, values)
        }

        fun returnToApp(): Boolean {
            val bridge = current ?: return false
            return try {
                bridge.activity.startActivity(Intent(bridge.activity, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                })
                true
            } catch (_: Exception) {
                action("error", mapOf("message" to "无法返回应用，请从桌面或运行通知打开提词器；MIUI 用户请检查“后台弹出界面”权限。"))
                false
            }
        }

        fun openCamera() {
            val bridge = current ?: return
            try {
                val intent = Intent(MediaStore.INTENT_ACTION_VIDEO_CAMERA)
                if (intent.resolveActivity(bridge.activity.packageManager) != null) bridge.activity.startActivity(intent)
                else action("error", mapOf("message" to "没有找到相机，请从桌面手动打开手机相机。"))
            } catch (_: Exception) {
                action("error", mapOf("message" to "无法打开相机，请手动切换到手机相机。"))
            }
        }
    }
}

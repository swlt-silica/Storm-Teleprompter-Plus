package com.example.storm_teleprompter_plus

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.storm_teleprompter_plus.overlay.OverlayBridge

class MainActivity : FlutterActivity() {
    private var overlayBridge: OverlayBridge? = null
    private var updateChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        overlayBridge = OverlayBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "storm.teleprompter/update",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("INVALID_PATH", "APK 路径为空", null)
                    return@setMethodCallHandler
                }
                try {
                    installApk(path)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("INSTALL_FAILED", error.message, null)
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (overlayBridge?.onRequestPermissionsResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updateChannel?.setMethodCallHandler(null)
        updateChannel = null
        overlayBridge?.dispose()
        overlayBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun installApk(path: String) {
        val apk = File(path)
        check(apk.isFile) { "更新文件不存在" }
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}

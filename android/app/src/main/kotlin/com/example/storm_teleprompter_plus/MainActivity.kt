package com.example.storm_teleprompter_plus

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.storm_teleprompter_plus.overlay.OverlayBridge

class MainActivity : FlutterActivity() {
    private var overlayBridge: OverlayBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        overlayBridge = OverlayBridge(this, flutterEngine.dartExecutor.binaryMessenger)
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
        overlayBridge?.dispose()
        overlayBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

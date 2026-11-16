package com.example.storm_teleprompter_plus.overlay

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Android grants an active accessibility service concurrent microphone eligibility.
 * There are no event subscriptions and canRetrieveWindowContent is false in the XML.
 * Firmware may still restrict simultaneous capture; the app does not promise otherwise.
 */
class TeleprompterAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        current = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (current === this) current = null
        // Removing this service also invalidates any window attached to its token.
        TeleprompterOverlayService.current?.onAccessibilityDisabled()
        super.onDestroy()
    }

    companion object {
        var current: TeleprompterAccessibilityService? = null
            private set
    }
}

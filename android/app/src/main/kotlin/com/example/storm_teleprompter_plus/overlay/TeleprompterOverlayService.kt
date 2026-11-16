package com.example.storm_teleprompter_plus.overlay

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.text.SpannableString
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import com.example.storm_teleprompter_plus.MainActivity
import com.example.storm_teleprompter_plus.R
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A user-started, in-process foreground service. Flutter retains the script, timer and
 * recognizer; this service renders their state without a camera or another ASR engine.
 * All windows are removed on stop, task dismissal, engine detachment or permission loss.
 */
class TeleprompterOverlayService : Service() {
    private var config = OverlayConfig()
    private var manager: WindowManager? = null
    private var panel: LinearLayout? = null
    private var unlockButton: Button? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var unlockParams: WindowManager.LayoutParams? = null
    private var textView: TextView? = null
    private var scrollView: ScrollView? = null
    private var statusView: TextView? = null
    private var playButton: Button? = null
    private var lockButton: Button? = null
    private var settingsPane: LinearLayout? = null
    private var settingsScroller: ScrollView? = null
    private var isLocked = false
    private var wasAccessibilityWindow = false
    private var foregroundMode: String? = null
    private var isStopping = false
    private var controlsUpdating = false
    private var fontSeek: SeekBar? = null
    private var opacitySeek: SeekBar? = null
    private var mirrorSwitch: Switch? = null
    private val preferences by lazy { getSharedPreferences("teleprompter_overlay", Context.MODE_PRIVATE) }

    val isShowing: Boolean get() = panel?.isAttachedToWindow == true && !isStopping

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        config = config.merge(mapOf(
            "fontSize" to preferences.getFloat("fontSize", config.fontSize),
            "backgroundOpacity" to preferences.getFloat("backgroundOpacity", config.backgroundOpacity),
            "widthFraction" to preferences.getFloat("widthFraction", config.widthFraction),
            "heightFraction" to preferences.getFloat("heightFraction", config.heightFraction),
            "mirror" to preferences.getBoolean("mirror", false),
        ))
        isLocked = preferences.getBoolean("locked", false)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopByUser()
            return START_NOT_STICKY
        }
        try {
            val payload = pendingPayload ?: emptyMap<String, Any>()
            pendingPayload = null
            config = config.merge(payload)
            check(config.text.isNotBlank()) { "当前稿件没有可显示的台词" }
            validatePermissions()
            ensureForeground()
            if (panel == null) buildWindow() else render()
            startResult?.success(true)
            startResult = null
        } catch (error: Exception) {
            startResult?.error("overlay_start_failed", "无法开启悬浮提词：${error.message ?: "请检查权限后重试"}", null)
            startResult = null
            stopByUser()
        }
        // A killed process must never resurrect a microphone or an old script automatically.
        return START_NOT_STICKY
    }

    private fun validatePermissions() {
        check(Settings.canDrawOverlays(this)) { "请先允许显示在其他应用上层" }
        if (config.mode == "asr") {
            check(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "请先允许麦克风权限" }
            check(TeleprompterAccessibilityService.current != null) { "请先启用“相机悬浮跟读”无障碍服务" }
        }
    }

    private fun ensureForeground() {
        if (foregroundMode == config.mode) return
        val notificationManager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            notificationManager.createNotificationChannel(NotificationChannel(
                NOTIFICATION_CHANNEL, getString(R.string.overlay_notification_channel), NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) })
        }
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1,
            Intent(this, TeleprompterOverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, NOTIFICATION_CHANNEL) else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle(getString(R.string.overlay_notification_title))
            .setContentText(getString(R.string.overlay_notification_text))
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, getString(R.string.overlay_notification_stop), stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                (if (config.mode == "asr") ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
            startForeground(NOTIFICATION_ID, notification, type)
        } else if (Build.VERSION.SDK_INT >= 29 && config.mode == "asr") {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregroundMode = config.mode
    }

    fun update(values: Map<*, *>) {
        if (isStopping) return
        val previous = config
        config = config.merge(values)
        try {
            validatePermissions()
            ensureForeground()
            if (previous != config) {
                if (previous.fontSize != config.fontSize ||
                    previous.backgroundOpacity != config.backgroundOpacity ||
                    previous.widthFraction != config.widthFraction ||
                    previous.heightFraction != config.heightFraction ||
                    previous.mirror != config.mirror) saveAppearance()
                render()
            }
        } catch (error: Exception) {
            OverlayBridge.action("error", mapOf("message" to "悬浮提词已停止：${error.message}"))
            stopByUser()
        }
    }

    private fun buildWindow() {
        val accessibility = TeleprompterAccessibilityService.current
        wasAccessibilityWindow = accessibility != null
        val windowContext: Context = accessibility ?: this
        manager = windowContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val type = when {
            wasAccessibilityWindow -> WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
            Build.VERSION.SDK_INT >= 26 -> WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else -> @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        }
        val window = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        panel = window

        val header = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            orientation = LinearLayout.HORIZONTAL
            minimumHeight = dp(44)
        }
        statusView = label("拖动移动 · ${config.status}", 13f).apply {
            setPadding(dp(6), 0, dp(4), 0)
            maxLines = 2
            contentDescription = "拖动这里移动台词窗"
        }
        header.addView(statusView, LinearLayout.LayoutParams(0, dp(44), 1f))
        header.addView(button("关闭") { stopByUser() })
        attachDrag(header)
        statusView?.let { attachDrag(it) }
        window.addView(header)

        textView = TextView(this).apply {
            setTextColor(config.textColor)
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
            setPadding(dp(8), dp(12), dp(8), dp(20))
            setTextIsSelectable(false)
        }
        scrollView = ScrollView(this).apply {
            isFillViewport = false
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(textView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        }
        window.addView(scrollView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        val tools = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        playButton = button("播放") { OverlayBridge.action("togglePlay") }
        tools.addView(playButton)
        tools.addView(button("上一段") { OverlayBridge.action("rewind") })
        tools.addView(button("下一段") { OverlayBridge.action("forward") })
        lockButton = button("锁定穿透") { setLocked(true) }
        tools.addView(lockButton)
        tools.addView(button("显示设置") {
            settingsScroller?.visibility = if (settingsScroller?.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            sizeAndClamp()
            safelyUpdateWindow()
        })
        tools.addView(button("相机") { OverlayBridge.openCamera() })
        tools.addView(button("返回应用") { OverlayBridge.returnToApp() })
        val toolScroller = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = true
            addView(tools)
        }
        window.addView(toolScroller, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48)))

        settingsPane = buildSettings()
        settingsScroller = ScrollView(this).apply {
            visibility = View.GONE
            addView(settingsPane)
        }
        window.addView(settingsScroller, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(168)))
        val resizer = label("拖动右侧调整大小  ↘", 12f).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            minimumHeight = dp(28)
            setPadding(0, 0, dp(8), 0)
            contentDescription = "拖动调整台词窗宽度和高度"
        }
        attachResize(resizer)
        window.addView(resizer, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(28)))

        panelParams = WindowManager.LayoutParams(
            dp(320), dp(380), type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = preferences.getInt("x", dp(12))
            y = preferences.getInt("y", dp(64))
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        }
        sizeAndClamp()
        manager!!.addView(window, panelParams)
        render()
        if (isLocked) setLocked(true)
    }

    private fun buildSettings(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(6), dp(4), dp(6), dp(4))
            fontSeek = slider(this, "台词字号", 18, 100, config.fontSize.roundToInt()) { value ->
                changeAppearance(mapOf("fontSize" to value.toDouble()))
            }
            opacitySeek = slider(this, "背景不透明度", 0, 100, (config.backgroundOpacity * 100).roundToInt(), "%") { value ->
                changeAppearance(mapOf("backgroundOpacity" to value / 100.0))
            }
            // Resize is also available without opening settings, which leaves more reading space.
            mirrorSwitch = Switch(this@TeleprompterOverlayService).apply {
                text = "左右镜像（分光镜）"
                setTextColor(Color.WHITE)
                textSize = 14f
                isChecked = config.mirror
                minimumHeight = dp(44)
                setOnCheckedChangeListener { _, checked ->
                    if (!controlsUpdating) changeAppearance(mapOf("mirror" to checked))
                }
            }
            addView(mirrorSwitch)
            addView(button("更多设置") {
                OverlayBridge.returnToApp()
                OverlayBridge.action("settings")
            })
        }
    }

    private fun slider(parent: LinearLayout, title: String, min: Int, max: Int, initial: Int,
        suffix: String = "", onChanged: (Int) -> Unit): SeekBar {
        val caption = label("$title：$initial$suffix", 13f)
        parent.addView(caption)
        return SeekBar(this).apply {
            this.max = max - min
            progress = initial - min
            minimumHeight = dp(40)
            contentDescription = title
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit
                override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    val value = progress + min
                    caption.text = "$title：$value$suffix"
                    if (fromUser && !controlsUpdating) onChanged(value)
                }
            })
            parent.addView(this, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(40)))
        }
    }

    private fun render() {
        val window = panel ?: return
        window.background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor((config.backgroundColor and 0x00ffffff) or ((config.backgroundOpacity * 255).roundToInt() shl 24))
        }
        playButton?.text = if (config.isPlaying) "暂停" else "播放"
        statusView?.text = "拖动移动 · ${config.status}"
        controlsUpdating = true
        fontSeek?.progress = config.fontSize.roundToInt() - 18
        opacitySeek?.progress = (config.backgroundOpacity * 100).roundToInt()
        mirrorSwitch?.isChecked = config.mirror
        controlsUpdating = false

        val view = textView ?: return
        val index = config.currentIndex.coerceIn(-1, max(-1, config.text.length - 1))
        val styled = SpannableString(config.text)
        if (index > 0) {
            val oldColor = (config.textColor and 0x00ffffff) or (150 shl 24)
            styled.setSpan(ForegroundColorSpan(oldColor), 0, index, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (index >= 0 && index < config.text.length) {
            // Highlight a whole Unicode code point, including surrogate pairs.
            val start = if (index > 0 && Character.isLowSurrogate(config.text[index])) index - 1 else index
            val end = min(config.text.length, start + Character.charCount(Character.codePointAt(config.text, start)))
            styled.setSpan(BackgroundColorSpan(Color.argb(170, 219, 157, 22)), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        view.setTextColor(config.textColor)
        view.textSize = config.fontSize
        view.setLineSpacing(0f, config.lineHeight)
        view.scaleX = if (config.mirror) -1f else 1f
        view.text = styled
        sizeAndClamp()
        safelyUpdateWindow()
        view.post { followCurrentIndex() }
    }

    private fun followCurrentIndex() {
        val view = textView ?: return
        val layout = view.layout ?: return
        val scroll = scrollView ?: return
        val index = config.currentIndex.coerceIn(0, config.text.length)
        val line = layout.getLineForOffset(index)
        val desired = layout.getLineTop(line) + view.paddingTop - (scroll.height * 0.3f).roundToInt()
        val maxScroll = max(0, view.height - scroll.height)
        scroll.smoothScrollTo(0, desired.coerceIn(0, maxScroll))
    }

    private fun changeAppearance(values: Map<String, Any>) {
        config = config.merge(values)
        saveAppearance()
        render()
        OverlayBridge.action("updateSettings", values)
    }

    private fun saveAppearance() {
        preferences.edit()
            .putFloat("fontSize", config.fontSize)
            .putFloat("backgroundOpacity", config.backgroundOpacity)
            .putFloat("widthFraction", config.widthFraction)
            .putFloat("heightFraction", config.heightFraction)
            .putBoolean("mirror", config.mirror)
            .apply()
    }

    private fun screenSize(): Pair<Int, Int> {
        val metrics = resources.displayMetrics
        return metrics.widthPixels to metrics.heightPixels
    }

    private fun sizeAndClamp() {
        val params = panelParams ?: return
        val (screenWidth, screenHeight) = screenSize()
        params.width = (screenWidth * config.widthFraction).roundToInt().coerceIn(min(dp(220), screenWidth), screenWidth)
        // Leave some text visible even with a large system font; settings can be closed again.
        val minimumHeight = if (settingsScroller?.visibility == View.VISIBLE) dp(390) else dp(210)
        params.height = (screenHeight * config.heightFraction).roundToInt().coerceIn(min(minimumHeight, screenHeight), screenHeight)
        params.x = params.x.coerceIn(0, max(0, screenWidth - params.width))
        params.y = params.y.coerceIn(0, max(0, screenHeight - params.height - dp(24)))
        unlockParams?.let {
            it.x = params.x.coerceIn(0, max(0, screenWidth - it.width))
            it.y = (params.y + params.height - dp(44)).coerceIn(0, max(0, screenHeight - it.height - dp(24)))
        }
    }

    private fun attachDrag(handle: View) {
        var downX = 0f
        var downY = 0f
        var originalX = 0
        var originalY = 0
        handle.setOnTouchListener { _, event ->
            val params = panelParams ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY
                    originalX = params.x; originalY = params.y
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = originalX + (event.rawX - downX).roundToInt()
                    params.y = originalY + (event.rawY - downY).roundToInt()
                    sizeAndClamp(); safelyUpdateWindow()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    preferences.edit().putInt("x", params.x).putInt("y", params.y).apply()
                    true
                }
                else -> false
            }
        }
    }

    private fun attachResize(handle: View) {
        var downX = 0f
        var downY = 0f
        var startWidth = 0
        var startHeight = 0
        handle.setOnTouchListener { _, event ->
            val params = panelParams ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY
                    startWidth = params.width; startHeight = params.height
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val (sw, sh) = screenSize()
                    config = config.copy(
                        widthFraction = ((startWidth + event.rawX - downX) / sw).coerceIn(0.35f, 1f),
                        heightFraction = ((startHeight + event.rawY - downY) / sh).coerceIn(0.18f, 0.8f),
                    )
                    sizeAndClamp(); safelyUpdateWindow()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    saveAppearance()
                    OverlayBridge.action("updateSettings", mapOf(
                        "widthFraction" to config.widthFraction.toDouble(),
                        "heightFraction" to config.heightFraction.toDouble(),
                    ))
                    true
                }
                else -> false
            }
        }
    }

    private fun setLocked(locked: Boolean) {
        val params = panelParams ?: return
        isLocked = locked
        preferences.edit().putBoolean("locked", locked).apply()
        if (locked) {
            settingsScroller?.visibility = View.GONE
            params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            // Android 12 blocks pass-through under opaque untrusted application overlays.
            params.alpha = if (wasAccessibilityWindow) 1f else 0.78f
            if (unlockButton == null) {
                unlockButton = button("解锁台词窗") { setLocked(false) }
                unlockParams = WindowManager.LayoutParams(dp(120), dp(48), params.type,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                    PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.START }
                sizeAndClamp()
                manager?.addView(unlockButton, unlockParams)
            }
        } else {
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            params.alpha = 1f
            removeUnlockButton()
        }
        safelyUpdateWindow()
    }

    private fun safelyUpdateWindow() {
        try {
            if (panel?.isAttachedToWindow == true) manager?.updateViewLayout(panel, panelParams)
            if (unlockButton?.isAttachedToWindow == true) manager?.updateViewLayout(unlockButton, unlockParams)
        } catch (_: Exception) {
            stopByUser()
        }
    }

    private fun removeUnlockButton() {
        unlockButton?.let { runCatching { manager?.removeViewImmediate(it) } }
        unlockButton = null
        unlockParams = null
    }

    fun onAccessibilityDisabled() {
        if (wasAccessibilityWindow || config.mode == "asr") {
            OverlayBridge.action("error", mapOf("message" to "相机悬浮跟读服务已关闭，悬浮提词已停止。"))
            stopByUser()
        }
    }

    fun stopByUser(notifyFlutter: Boolean = true) {
        if (isStopping) return
        isStopping = true
        removeWindows()
        if (notifyFlutter) OverlayBridge.action("close")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun removeWindows() {
        removeUnlockButton()
        panel?.let { runCatching { manager?.removeViewImmediate(it) } }
        panel = null
        panelParams = null
        textView = null
        scrollView = null
        settingsPane = null
        settingsScroller = null
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        sizeAndClamp()
        safelyUpdateWindow()
        textView?.post { followCurrentIndex() }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopByUser()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (!isStopping) OverlayBridge.action("close")
        isStopping = true
        removeWindows()
        if (current === this) current = null
        startResult?.error("overlay_stopped", "悬浮提词已停止，请返回应用重试。", null)
        startResult = null
        super.onDestroy()
    }

    private fun label(value: String, size: Float) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(Color.WHITE)
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun button(value: String, action: () -> Unit) = Button(this).apply {
        text = value
        textSize = 13f
        isAllCaps = false
        minWidth = dp(64)
        minimumWidth = dp(64)
        minimumHeight = dp(44)
        setPadding(dp(10), 0, dp(10), 0)
        setTextColor(Color.WHITE)
        background = GradientDrawable().apply { cornerRadius = dp(6).toFloat(); setColor(Color.argb(225, 35, 35, 35)) }
        contentDescription = value
        setOnClickListener { action() }
    }

    private fun dp(value: Int) = (resources.displayMetrics.density * value).roundToInt()

    companion object {
        private const val ACTION_STOP = "com.example.storm_teleprompter_plus.STOP_OVERLAY"
        private const val NOTIFICATION_CHANNEL = "teleprompter_overlay"
        private const val NOTIFICATION_ID = 7341
        var current: TeleprompterOverlayService? = null
            private set
        var startResult: MethodChannel.Result? = null
        var pendingPayload: Map<*, *>? = null
    }
}

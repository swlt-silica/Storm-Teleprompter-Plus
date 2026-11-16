package com.example.storm_teleprompter_plus.overlay

import android.graphics.Color

/** Wire values use UTF-16 offsets, just like Dart string offsets and Android text spans. */
internal data class OverlayConfig(
    val text: String = "",
    val currentIndex: Int = -1,
    val isPlaying: Boolean = false,
    val mode: String = "auto",
    val fontSize: Float = 34f,
    val lineHeight: Float = 1.5f,
    val textColor: Int = Color.WHITE,
    val backgroundColor: Int = Color.BLACK,
    val backgroundOpacity: Float = 0.5f,
    val widthFraction: Float = 0.94f,
    val heightFraction: Float = 0.45f,
    val mirror: Boolean = false,
    val status: String = "已暂停",
) {
    fun merge(values: Map<*, *>): OverlayConfig {
        fun number(key: String, fallback: Float, min: Float, max: Float): Float {
            val value = (values[key] as? Number)?.toFloat() ?: fallback
            return if (value.isFinite()) value.coerceIn(min, max) else fallback
        }
        return copy(
            text = values["text"] as? String ?: text,
            currentIndex = (values["currentIndex"] as? Number)?.toInt() ?: currentIndex,
            isPlaying = values["isPlaying"] as? Boolean ?: isPlaying,
            mode = (values["mode"] as? String)?.takeIf { it == "auto" || it == "asr" } ?: mode,
            fontSize = number("fontSize", fontSize, 18f, 100f),
            lineHeight = number("lineHeight", lineHeight, 1f, 3f),
            textColor = (values["textColor"] as? Number)?.toLong()?.toInt()?.takeIf { it != 0 } ?: textColor,
            backgroundColor = (values["backgroundColor"] as? Number)?.toLong()?.toInt() ?: backgroundColor,
            backgroundOpacity = number("backgroundOpacity", backgroundOpacity, 0f, 1f),
            widthFraction = number("widthFraction", widthFraction, 0.35f, 1f),
            heightFraction = number("heightFraction", heightFraction, 0.18f, 0.8f),
            mirror = values["mirror"] as? Boolean ?: mirror,
            status = values["status"] as? String ?: status,
        )
    }
}

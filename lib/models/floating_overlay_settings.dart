/// 安卓悬浮提词的全局外观设置，随完整应用备份保存。
class FloatingOverlaySettings {
  const FloatingOverlaySettings({
    this.fontSize = 32,
    this.backgroundOpacity = 0.45,
    this.widthFraction = 0.9,
    this.heightFraction = 0.42,
    this.mirror = false,
  });

  final double fontSize;
  final double backgroundOpacity;
  final double widthFraction;
  final double heightFraction;
  final bool mirror;

  factory FloatingOverlaySettings.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback, double min, double max) {
      final value = json[key];
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max);
    }

    return FloatingOverlaySettings(
      fontSize: read('fontSize', 32, 18, 100),
      backgroundOpacity: read('backgroundOpacity', 0.45, 0, 1),
      widthFraction: read('widthFraction', 0.9, 0.35, 1),
      heightFraction: read('heightFraction', 0.42, 0.18, 0.8),
      mirror: json['mirror'] == true,
    );
  }

  FloatingOverlaySettings copyWith({
    double? fontSize,
    double? backgroundOpacity,
    double? widthFraction,
    double? heightFraction,
    bool? mirror,
  }) => FloatingOverlaySettings.fromJson({
    ...toJson(),
    if (fontSize != null) 'fontSize': fontSize,
    if (backgroundOpacity != null) 'backgroundOpacity': backgroundOpacity,
    if (widthFraction != null) 'widthFraction': widthFraction,
    if (heightFraction != null) 'heightFraction': heightFraction,
    if (mirror != null) 'mirror': mirror,
  });

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'backgroundOpacity': backgroundOpacity,
    'widthFraction': widthFraction,
    'heightFraction': heightFraction,
    'mirror': mirror,
  };
}

import 'package:pinyin/pinyin.dart';

/// Compares Chinese characters using a conservative Mandarin pronunciation
/// equivalence relation for teleprompter alignment.
class ChinesePronunciationMatcher {
  const ChinesePronunciationMatcher._();

  static double similarity(String left, String right) {
    if (left == right) return 1.0;
    if (left.runes.length != 1 || right.runes.length != 1) return 0.0;

    final leftPinyin = _pinyin(left);
    final rightPinyin = _pinyin(right);
    if (leftPinyin == null || rightPinyin == null) return 0.0;
    if (leftPinyin == rightPinyin) return 0.82;
    if (_normalizeForCommonConfusions(leftPinyin) ==
        _normalizeForCommonConfusions(rightPinyin)) {
      return 0.62;
    }
    return 0.0;
  }

  static bool equivalent(String left, String right) => similarity(left, right) > 0;

  static String? _pinyin(String character) {
    final values = PinyinHelper.convertToPinyinArray(
      character,
      PinyinFormat.WITHOUT_TONE,
    );
    if (values.isEmpty) return null;
    return values.first;
  }

  static String _normalizeForCommonConfusions(String pinyin) {
    var value = pinyin;

    // Retroflex and flat sibilants are commonly confused in Mandarin speech.
    value = value.replaceFirst(RegExp(r'^zh'), 'z');
    value = value.replaceFirst(RegExp(r'^ch'), 'c');
    value = value.replaceFirst(RegExp(r'^sh'), 's');

    // Common initial confusion in fast or regional Mandarin speech.
    value = value.replaceFirst(RegExp(r'^l'), 'n');
    value = value.replaceFirst(RegExp(r'^h'), 'f');

    // Common nasal ending and final confusion.
    value = value.replaceFirst(RegExp(r'ng$'), 'n');
    value = value.replaceFirst(RegExp(r'ang$'), 'an');
    value = value.replaceFirst(RegExp(r'eng$'), 'en');
    value = value.replaceFirst(RegExp(r'ing$'), 'in');
    value = value.replaceFirst(RegExp(r'iang$'), 'ian');

    return value;
  }
}

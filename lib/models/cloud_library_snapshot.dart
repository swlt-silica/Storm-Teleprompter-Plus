import 'dart:convert';

/// 云端稿库传输格式。正文是权威数据，HTML 始终在本机重新生成。
class CloudLibrarySnapshot {
  const CloudLibrarySnapshot({
    required this.libraryId,
    required this.revision,
    required this.scripts,
  });

  static const format = 'storm-cloud-library';
  static const version = 1;
  static const maxScripts = 1000;
  static const maxBodyCharacters = 50000;
  static const maxContentCharacters = 400000;
  static const maxTotalBodyCharacters = 8000000;
  static const maxTotalContentCharacters = 24000000;
  static final _libraryIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final _scriptIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  static final _timestampPattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$',
  );

  final String libraryId;
  final int revision;
  final List<CloudLibraryScript> scripts;

  factory CloudLibrarySnapshot.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format || json['version'] != version) {
      throw const FormatException('云端稿库格式或版本不受支持');
    }
    final id = json['libraryId'];
    if (id is! String || !_libraryIdPattern.hasMatch(id)) {
      throw const FormatException('云端稿库 libraryId 必须是 UUID');
    }
    final revision = _readRevision(json['revision'], '稿库版本', allowZero: true);
    final values = json['scripts'];
    if (values is! List || values.length > maxScripts) {
      throw const FormatException('云端稿库最多包含 1000 篇稿件');
    }
    final ids = <String>{};
    final scripts = <CloudLibraryScript>[];
    var totalBody = 0;
    var totalContent = 0;
    for (final value in values) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('云端稿件数据格式无效');
      }
      final scriptId = value['scriptId'];
      if (scriptId is! String || !_scriptIdPattern.hasMatch(scriptId)) {
        throw const FormatException('脚本编号只能包含字母、数字、点、下划线和连字符，长度 1–64');
      }
      if (!ids.add(scriptId)) throw FormatException('脚本编号重复：$scriptId');
      if (value['title'] != scriptId) {
        throw FormatException('稿件标题必须与脚本编号相同：$scriptId');
      }
      final body = value['body'];
      final content = value['content'];
      if (body is! String ||
          body.trim().isEmpty ||
          body.length > maxBodyCharacters ||
          body.contains('\u0000')) {
        throw FormatException('正文不能为空、不能包含空字符且最多 50000 字符：$scriptId');
      }
      if (content is! String || content.length > maxContentCharacters) {
        throw FormatException('稿件 HTML 超出长度限制：$scriptId');
      }
      final safeContent = CloudLibraryScript.renderBody(body);
      if (safeContent.length > maxContentCharacters) {
        throw FormatException('正文转换后的 HTML 超出长度限制：$scriptId');
      }
      totalBody += body.length;
      // Include the actual HTML that will be stored even if a remote sender
      // supplied a much shorter, unrelated content field.
      totalContent += content.length > safeContent.length
          ? content.length
          : safeContent.length;
      if (totalBody > maxTotalBodyCharacters ||
          totalContent > maxTotalContentCharacters) {
        throw const FormatException('云端稿库正文总量超出本机导入限制');
      }
      final createdAt = _readTimestamp(value['createdAt'], '$scriptId 创建时间');
      final updatedAt = _readTimestamp(value['updatedAt'], '$scriptId 更新时间');
      if (updatedAt.isBefore(createdAt)) {
        throw FormatException('稿件更新时间不能早于创建时间：$scriptId');
      }
      final scriptRevision = _readRevision(value['revision'], '$scriptId 稿件版本');
      if (scriptRevision > revision) {
        throw FormatException('稿件版本不能高于稿库版本：$scriptId');
      }
      scripts.add(
        CloudLibraryScript(
          scriptId: scriptId,
          body: body,
          content: content,
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: scriptRevision,
        ),
      );
    }
    return CloudLibrarySnapshot(
      libraryId: id.toLowerCase(),
      revision: revision,
      scripts: List.unmodifiable(scripts),
    );
  }

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'libraryId': libraryId,
    'revision': revision,
    'scripts': scripts.map((script) => script.toJson()).toList(),
  };

  static int _readRevision(
    dynamic value,
    String label, {
    bool allowZero = false,
  }) {
    if (value is! int ||
        value < (allowZero ? 0 : 1) ||
        value > 9007199254740991) {
      throw FormatException('$label 无效');
    }
    return value;
  }

  static DateTime _readTimestamp(dynamic value, String label) {
    if (value is! String) throw FormatException('$label 必须为 UTC 时间');
    final match = _timestampPattern.firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null || parsed == null || !parsed.isUtc) {
      throw FormatException('$label 必须为有效 ISO 8601 UTC 时间');
    }
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    if (parsed.year != parts[0] ||
        parsed.month != parts[1] ||
        parsed.day != parts[2] ||
        parsed.hour != parts[3] ||
        parsed.minute != parts[4] ||
        parsed.second != parts[5]) {
      throw FormatException('$label 超出有效日历范围');
    }
    return parsed;
  }
}

class CloudLibraryScript {
  const CloudLibraryScript({
    required this.scriptId,
    required this.body,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
  });

  final String scriptId;
  final String body;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;

  String localId(String libraryId) => 'cloud:$libraryId:$scriptId';

  /// 不将远端 HTML 送入富文本编辑器，避免脚本、链接或隐藏内容进入台词。
  String get safeContent => renderBody(body);

  static String renderBody(String body) => body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(
        (line) =>
            '<p>${const HtmlEscape(HtmlEscapeMode.element).convert(line)}</p>',
      )
      .join('\n');

  Map<String, dynamic> toJson() => {
    'scriptId': scriptId,
    'title': scriptId,
    'body': body,
    'content': content,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'revision': revision,
  };
}

class CloudLibraryImportResult {
  const CloudLibraryImportResult({
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.total,
  });

  final int created;
  final int updated;
  final int unchanged;
  final int total;

  Map<String, dynamic> toJson() => {
    'created': created,
    'updated': updated,
    'unchanged': unchanged,
    'total': total,
  };
}

import 'dart:convert';

import 'article.dart';
import 'folder.dart';

/// A complete shared library, deliberately excluding device/account settings.
class CloudLibraryBackup {
  const CloudLibraryBackup({
    required this.createdAt,
    required this.articles,
    required this.folders,
  });

  static const format = 'storm-cloud-backup';
  static const version = 1;
  static const maxBytes = 32 * 1024 * 1024 - 1024;
  static const maxItems = 1000;
  static const maxArticleContent = 400000;
  static const maxTotalContent = 24000000;

  final DateTime createdAt;
  final List<Article> articles;
  final List<Folder> folders;

  factory CloudLibraryBackup.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        !json.keys.toSet().containsAll({
          'format',
          'version',
          'createdAt',
          'articles',
          'folders',
        }) ||
        json['format'] != format ||
        json['version'] is! int ||
        json['version'] != version) {
      throw const FormatException('云端完整稿库格式或版本无效');
    }
    if (utf8.encode(jsonEncode(json)).length > maxBytes) {
      throw const FormatException('完整稿库不能超过 32 MiB');
    }
    final createdAt = _date(json['createdAt'], '备份时间');
    final articleValues = json['articles'];
    final folderValues = json['folders'];
    if (articleValues is! List ||
        folderValues is! List ||
        articleValues.length > maxItems ||
        folderValues.length > maxItems) {
      throw const FormatException('完整稿库最多包含 1000 篇稿件和 1000 个文件夹');
    }
    final folderIds = <String>{};
    final folders = <Folder>[];
    for (final value in folderValues) {
      final data = _map(value);
      _keys(data, {'id', 'name', 'createdAt', 'sortOrder'}, {'parentId'});
      final id = _id(data['id']);
      if (!folderIds.add(id)) throw const FormatException('文件夹 ID 重复');
      final parentId = data['parentId'] == null ? null : _id(data['parentId']);
      final name = _text(data['name'], '文件夹名称', 512);
      if (name.trim().isEmpty) throw const FormatException('文件夹名称不能为空');
      folders.add(
        Folder(
          id: id,
          name: name,
          parentId: parentId,
          createdAt: _date(data['createdAt'], '文件夹创建时间'),
          sortOrder: _order(data['sortOrder']),
        ),
      );
    }
    final byFolderId = {for (final folder in folders) folder.id: folder};
    for (final folder in folders) {
      final visited = <String>{folder.id};
      var parentId = folder.parentId;
      while (parentId != null) {
        if (!folderIds.contains(parentId))
          throw const FormatException('文件夹引用不存在的父目录');
        if (!visited.add(parentId)) throw const FormatException('文件夹层级存在循环');
        parentId = byFolderId[parentId]!.parentId;
      }
    }
    final articleIds = <String>{};
    final articles = <Article>[];
    var totalContent = 0;
    for (final value in articleValues) {
      final data = _map(value);
      _keys(
        data,
        {'id', 'title', 'content', 'createdAt', 'updatedAt', 'sortOrder'},
        {'folderId'},
      );
      final id = _id(data['id']);
      if (!articleIds.add(id)) throw const FormatException('稿件 ID 重复');
      final folderId = data['folderId'] == null ? null : _id(data['folderId']);
      if (folderId != null && !folderIds.contains(folderId)) {
        throw const FormatException('稿件引用不存在的文件夹');
      }
      final content = _text(data['content'], '稿件正文', maxArticleContent);
      totalContent += content.length;
      if (totalContent > maxTotalContent)
        throw const FormatException('稿件正文总量超出限制');
      final articleCreated = _date(data['createdAt'], '稿件创建时间');
      final updatedAt = _date(data['updatedAt'], '稿件更新时间');
      if (updatedAt.isBefore(articleCreated))
        throw const FormatException('稿件更新时间早于创建时间');
      articles.add(
        Article(
          id: id,
          title: _text(data['title'], '稿件标题', 512),
          content: content,
          createdAt: articleCreated,
          updatedAt: updatedAt,
          sortOrder: _order(data['sortOrder']),
          folderId: folderId,
        ),
      );
    }
    return CloudLibraryBackup(
      createdAt: createdAt,
      articles: List.unmodifiable(articles),
      folders: List.unmodifiable(folders),
    );
  }

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'articles': [
      for (final article in articles)
        {
          'id': article.id,
          'title': article.title,
          'content': article.content,
          'createdAt': article.createdAt.toUtc().toIso8601String(),
          'updatedAt': article.updatedAt.toUtc().toIso8601String(),
          'sortOrder': article.sortOrder,
          'folderId': article.folderId,
        },
    ],
    'folders': [
      for (final folder in folders)
        {
          'id': folder.id,
          'name': folder.name,
          'parentId': folder.parentId,
          'createdAt': folder.createdAt.toUtc().toIso8601String(),
          'sortOrder': folder.sortOrder,
        },
    ],
  };

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException('稿库记录无效');
    return value;
  }

  static void _keys(
    Map<String, dynamic> data,
    Set<String> required,
    Set<String> optional,
  ) {
    if (!data.keys.toSet().containsAll(required) ||
        data.keys.any(
          (key) => !required.contains(key) && !optional.contains(key),
        )) {
      throw const FormatException('稿库记录包含缺失或不支持的字段');
    }
  }

  static String _id(dynamic value) {
    final id = _text(value, '稿库记录 ID', 256);
    if (id.trim().isEmpty) {
      throw const FormatException('稿库记录 ID 无效');
    }
    return id;
  }

  static String _text(dynamic value, String label, int limit) {
    if (value is! String || value.length > limit || value.contains('\u0000')) {
      throw FormatException('$label 无效或超过长度限制');
    }
    return value;
  }

  static int _order(dynamic value) {
    if (value is! int || value.abs() > 9007199254740991)
      throw const FormatException('排序值无效');
    return value;
  }

  static DateTime _date(dynamic value, String label) {
    if (value is! String) throw FormatException('$label 无效');
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$',
    ).firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null || parsed == null || parsed.year < 1 || !parsed.isUtc)
      throw FormatException('$label 必须为 UTC 时间');
    final fields = [
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
    ];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i] != int.parse(match.group(i + 1)!))
        throw FormatException('$label 超出日历范围');
    }
    return parsed;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/ws_protocol.dart';
import '../models/cloud_library_snapshot.dart';
import '../models/cloud_library_backup.dart';
import '../providers/connection_provider.dart';
import '../providers/teleprompter_provider.dart';
import 'app_preferences.dart';

class CloudLibraryException implements Exception {
  const CloudLibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudLibraryCredentials {
  const CloudLibraryCredentials({
    this.baseUrl = '',
    this.readToken = '',
    this.uploadToken = '',
  });
  final String baseUrl;
  final String readToken;
  final String uploadToken;

  String get downloadToken =>
      readToken.trim().isNotEmpty ? readToken.trim() : uploadToken.trim();
}

/// Device-local connection credentials; deliberately outside AppSettings/backup.
class CloudLibraryCredentialStore {
  static const _key = 'cloud_library_connection_v1';

  Future<CloudLibraryCredentials> load() async {
    final raw = (await AppPreferences.getInstance()).getString(_key);
    if (raw == null || raw.isEmpty) return const CloudLibraryCredentials();
    try {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      return CloudLibraryCredentials(
        baseUrl: value['baseUrl'] as String? ?? '',
        readToken: value['readToken'] as String? ?? '',
        uploadToken: value['uploadToken'] as String? ?? '',
      );
    } catch (_) {
      throw const CloudLibraryException('云稿库连接配置无法读取，请重新填写');
    }
  }

  Future<void> save(CloudLibraryCredentials value) async {
    final normalized = CloudLibraryClient.normalizeBaseUrl(value.baseUrl);
    CloudLibraryClient.validateToken(value.downloadToken);
    if (value.uploadToken.isNotEmpty)
      CloudLibraryClient.validateToken(value.uploadToken);
    final saved = await (await AppPreferences.getInstance()).setString(
      _key,
      jsonEncode({
        'baseUrl': normalized.toString(),
        'readToken': value.readToken.trim(),
        'uploadToken': value.uploadToken.trim(),
      }),
    );
    if (!saved) {
      throw const CloudLibraryException('连接配置未能保存，请检查本机存储后重试');
    }
  }
}

class CloudLibraryClient {
  CloudLibraryClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static const timeout = Duration(seconds: 20);
  static const maxResponseBytes = 32 * 1024 * 1024;

  static Uri normalizeBaseUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const CloudLibraryException('请填写不含账号、查询参数或片段的 HTTPS 服务地址');
    }
    final loopback =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !loopback) {
      throw const CloudLibraryException('公网云稿库必须使用 HTTPS');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: path);
  }

  static void validateToken(String input) {
    if (input.trim().isEmpty || input.contains(RegExp(r'[\r\n]'))) {
      throw const CloudLibraryException('请填写有效的访问令牌');
    }
  }

  Future<CloudLibrarySnapshot> download(
    CloudLibraryCredentials credentials,
  ) async {
    final base = normalizeBaseUrl(credentials.baseUrl);
    validateToken(credentials.downloadToken);
    final endpoint = base.replace(path: '${base.path}/api/v1/library');
    final abort = Completer<void>();
    try {
      return await _download(
        endpoint,
        credentials.downloadToken,
        abort.future,
      ).timeout(timeout);
    } on CloudLibraryException {
      rethrow;
    } on FormatException {
      throw const CloudLibraryException('云稿库数据格式不正确，未修改本地稿件');
    } on TimeoutException {
      throw const CloudLibraryException('云稿库请求超时，请检查网络后重试');
    } catch (_) {
      // Do not expose a URL, Authorization header or server response body.
      throw const CloudLibraryException('无法下载云稿库，请检查地址和网络连接');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<CloudLibrarySnapshot> _download(
    Uri endpoint,
    String token,
    Future<void> abortTrigger,
  ) async {
    final request =
        http.AbortableRequest('GET', endpoint, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $token';
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const CloudLibraryException('下载令牌无效或无权访问，请核对下载令牌');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const CloudLibraryException('服务地址发生跳转，请填写最终的 HTTPS 云稿库地址');
      }
      throw CloudLibraryException('云稿库服务暂不可用（HTTP ${response.statusCode}）');
    }
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      await response.stream.listen(null).cancel();
      throw const CloudLibraryException('云稿库响应过大，未修改本地稿件');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const CloudLibraryException('云稿库响应过大，未修改本地稿件');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    return CloudLibrarySnapshot.fromJson(decoded);
  }

  Future<CloudLibraryBackup> downloadBackup(
    CloudLibraryCredentials credentials,
  ) async {
    final json = await _requestJson(
      credentials: credentials,
      method: 'GET',
      token: credentials.downloadToken,
    );
    final revision = json['revision'];
    if (revision is! int ||
        revision < 0 ||
        json['backup'] is! Map<String, dynamic>) {
      throw const CloudLibraryException('云稿库整库备份格式不正确，未修改本地稿件');
    }
    try {
      return CloudLibraryBackup.fromJson(
        json['backup'] as Map<String, dynamic>,
      );
    } on FormatException {
      throw const CloudLibraryException('云稿库整库备份格式不正确，未修改本地稿件');
    }
  }

  Future<CloudLibraryTransferResult> uploadBackup(
    CloudLibraryCredentials credentials,
    CloudLibraryBackup backup,
  ) async {
    if (credentials.uploadToken.trim().isEmpty) {
      throw const CloudLibraryException('上传整库需要上传令牌');
    }
    // Round-trip through the strict model to remove device-only fields.
    final validated = CloudLibraryBackup.fromJson(backup.toJson());
    final json = await _requestJson(
      credentials: credentials,
      method: 'PUT',
      token: credentials.uploadToken.trim(),
      body: validated.toJson(),
    );
    if (json['success'] != true || json['revision'] is! int) {
      throw const CloudLibraryException('服务端未确认上传成功，请重试');
    }
    final result = CloudLibraryTransferResult.fromJson(json);
    if (result.articles != validated.articles.length ||
        result.folders != validated.folders.length) {
      throw const CloudLibraryException('服务端上传结果与本机稿库不一致，请检查后重试');
    }
    return result;
  }

  Future<Map<String, dynamic>> _requestJson({
    required CloudLibraryCredentials credentials,
    required String method,
    required String token,
    Map<String, dynamic>? body,
  }) async {
    final base = normalizeBaseUrl(credentials.baseUrl);
    validateToken(token);
    final endpoint = base.replace(path: '${base.path}/api/v1/backup');
    final bodyBytes = body == null ? null : utf8.encode(jsonEncode(body));
    if ((bodyBytes?.length ?? 0) > maxResponseBytes) {
      throw const CloudLibraryException('整库备份超过 32 MiB，未上传');
    }
    final abort = Completer<void>();
    Future<Map<String, dynamic>> perform() async {
      final request =
          http.AbortableRequest(method, endpoint, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Accept'] = 'application/json'
            ..headers['Authorization'] = 'Bearer $token';
      if (bodyBytes != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.bodyBytes = bodyBytes;
      }
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        if (method == 'GET' && response.statusCode == 404) {
          throw const CloudLibraryException(
            '云端尚无整库备份，或服务地址有误。请核对地址后，先在有稿件的设备上传整库',
          );
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const CloudLibraryException('令牌无效或无此操作权限，请核对下载或上传令牌');
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const CloudLibraryException('服务地址发生跳转，请填写最终的 HTTPS 云稿库地址');
        }
        throw CloudLibraryException('云稿库操作失败（HTTP ${response.statusCode}）');
      }
      if ((response.contentLength ?? 0) > maxResponseBytes) {
        await response.stream.listen(null).cancel();
        throw const CloudLibraryException('云稿库响应过大，未修改本地稿件');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const CloudLibraryException('云稿库响应过大，未修改本地稿件');
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    }

    try {
      return await perform().timeout(timeout);
    } on CloudLibraryException {
      rethrow;
    } on FormatException {
      throw const CloudLibraryException('云稿库响应格式不正确，未修改本地稿件');
    } on TimeoutException {
      throw const CloudLibraryException('云稿库请求超时，请检查网络；上传可能已提交，请下载核对后再重试');
    } catch (_) {
      throw const CloudLibraryException('云稿库操作失败，请检查地址和网络连接');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void close() => _client.close();
}

class CloudLibraryTransferResult {
  const CloudLibraryTransferResult({
    required this.articles,
    required this.folders,
    this.revision,
  });
  final int articles;
  final int folders;
  final int? revision;

  factory CloudLibraryTransferResult.fromJson(Map<String, dynamic> json) {
    int count(String key) {
      final value = json[key];
      if (value is! int || value < 0)
        throw const CloudLibraryException('整库传输统计无效，请检查稿库');
      return value;
    }

    final revision = json['revision'];
    if (revision != null && (revision is! int || revision < 0)) {
      throw const CloudLibraryException('云稿库版本无效');
    }
    return CloudLibraryTransferResult(
      articles: count('articles'),
      folders: count('folders'),
      revision: revision as int?,
    );
  }
}

/// Transfers only articles/folders through the bundled backend, never device settings.
class CloudLibrarySyncService {
  CloudLibrarySyncService({CloudLibraryClient? client})
    : client = client ?? CloudLibraryClient();
  final CloudLibraryClient client;

  void _checkLocal(
    ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage,
  ) {
    if (!allowedFromPage || teleprompter?.isPlaying == true) {
      throw const CloudLibraryException('请先退出提词页面，再传输云端稿库');
    }
    if (!connection.isConnected || !connection.isLocal) {
      throw const CloudLibraryException('请先切回本机服务端，再传输云端稿库');
    }
  }

  Future<CloudLibraryTransferResult> downloadToLocal({
    required CloudLibraryCredentials credentials,
    required ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage = true,
  }) async {
    _checkLocal(connection, teleprompter, allowedFromPage);
    final backup = await client.downloadBackup(credentials);
    _checkLocal(connection, teleprompter, allowedFromPage);
    final response = await connection.request(
      WsMessageType.articleCloudRestore,
      data: backup.toJson(),
      timeout: const Duration(seconds: 20),
    );
    if (response.type != WsMessageType.articleCloudRestoreResponse ||
        response.data['success'] != true) {
      throw const CloudLibraryException('本机未能恢复整库，请检查后重试');
    }
    final result = CloudLibraryTransferResult.fromJson(response.data);
    if (result.articles != backup.articles.length ||
        result.folders != backup.folders.length) {
      throw const CloudLibraryException('本机恢复结果与云端整库不一致，请检查稿件列表');
    }
    return result;
  }

  Future<CloudLibraryTransferResult> uploadFromLocal({
    required CloudLibraryCredentials credentials,
    required ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage = true,
  }) async {
    _checkLocal(connection, teleprompter, allowedFromPage);
    if (credentials.uploadToken.trim().isEmpty)
      throw const CloudLibraryException('上传整库需要上传令牌');
    CloudLibraryClient.validateToken(credentials.uploadToken);
    final response = await connection.request(
      WsMessageType.articleCloudExport,
      timeout: const Duration(seconds: 20),
    );
    if (response.type != WsMessageType.articleCloudExportResponse) {
      throw const CloudLibraryException('无法导出本机稿库，未上传');
    }
    final CloudLibraryBackup backup;
    try {
      backup = CloudLibraryBackup.fromJson(response.data);
    } on FormatException {
      throw const CloudLibraryException('本机稿库格式无效，未上传');
    }
    _checkLocal(connection, teleprompter, allowedFromPage);
    return client.uploadBackup(credentials, backup);
  }

  void close() => client.close();
}

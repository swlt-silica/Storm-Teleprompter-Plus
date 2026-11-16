import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/ws_protocol.dart';
import '../models/cloud_library_snapshot.dart';
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
  const CloudLibraryCredentials({this.baseUrl = '', this.readToken = ''});
  final String baseUrl;
  final String readToken;
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
      );
    } catch (_) {
      throw const CloudLibraryException('云稿库连接配置无法读取，请重新填写');
    }
  }

  Future<void> save(CloudLibraryCredentials value) async {
    final normalized = CloudLibraryClient.normalizeBaseUrl(value.baseUrl);
    CloudLibraryClient.validateToken(value.readToken);
    await (await AppPreferences.getInstance()).setString(
      _key,
      jsonEncode({
        'baseUrl': normalized.toString(),
        'readToken': value.readToken.trim(),
      }),
    );
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
      throw const CloudLibraryException('请填写有效的下载令牌');
    }
  }

  Future<CloudLibrarySnapshot> download(
    CloudLibraryCredentials credentials,
  ) async {
    final base = normalizeBaseUrl(credentials.baseUrl);
    validateToken(credentials.readToken);
    final endpoint = base.replace(path: '${base.path}/api/v1/library');
    final abort = Completer<void>();
    try {
      return await _download(
        endpoint,
        credentials.readToken.trim(),
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

  void close() => _client.close();
}

class CloudLibrarySyncResult {
  const CloudLibrarySyncResult({
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.total,
  });
  final int created;
  final int updated;
  final int unchanged;
  final int total;
}

/// Imports through the bundled backend without switching the playback connection.
class CloudLibrarySyncService {
  CloudLibrarySyncService({CloudLibraryClient? client})
    : client = client ?? CloudLibraryClient();
  final CloudLibraryClient client;

  Future<CloudLibrarySyncResult> downloadToLocal({
    required CloudLibraryCredentials credentials,
    required ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage = true,
  }) async {
    void checkLocal() {
      if (!allowedFromPage || teleprompter?.isPlaying == true) {
        throw const CloudLibraryException('请先退出提词页面，再下载云端稿件');
      }
      if (!connection.isConnected || !connection.isLocal) {
        throw const CloudLibraryException('请先切回本机服务端，再下载云端稿件');
      }
    }

    checkLocal();
    final snapshot = await client.download(credentials);
    checkLocal();
    final response = await connection.request(
      WsMessageType.articleCloudImport,
      data: snapshot.toJson(),
      timeout: const Duration(seconds: 20),
    );
    if (response.type != WsMessageType.articleCloudImportResponse) {
      throw const CloudLibraryException('本机未能导入云稿库，请重试');
    }
    int count(String key) {
      final value = response.data[key];
      if (value is! int || value < 0)
        throw const CloudLibraryException('本机导入结果无效，请刷新稿件列表');
      return value;
    }

    return CloudLibrarySyncResult(
      created: count('created'),
      updated: count('updated'),
      unchanged: count('unchanged'),
      total: count('total'),
    );
  }

  void close() => client.close();
}

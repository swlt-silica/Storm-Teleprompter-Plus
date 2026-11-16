import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/article_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/teleprompter_provider.dart';
import '../../services/cloud_library_service.dart';

class CloudLibrarySettingsSection extends StatefulWidget {
  const CloudLibrarySettingsSection({
    super.key,
    this.syncAllowed = true,
    this.store,
    this.syncService,
  });
  final bool syncAllowed;
  final CloudLibraryCredentialStore? store;
  final CloudLibrarySyncService? syncService;

  @override
  State<CloudLibrarySettingsSection> createState() =>
      _CloudLibrarySettingsSectionState();
}

class _CloudLibrarySettingsSectionState
    extends State<CloudLibrarySettingsSection> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  late final _store = widget.store ?? CloudLibraryCredentialStore();
  late final _service = widget.syncService ?? CloudLibrarySyncService();
  bool _loading = true;
  bool _busy = false;
  bool _showToken = false;
  bool _saved = false;
  String? _message;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final credentials = await _store.load();
      if (!mounted) return;
      _url.text = credentials.baseUrl;
      _token.text = credentials.readToken;
      setState(() => _saved = credentials.baseUrl.isNotEmpty);
    } catch (_) {
      if (mounted)
        setState(() {
          _message = '连接配置读取失败，请重新填写';
          _error = true;
        });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  CloudLibraryCredentials get _credentials =>
      CloudLibraryCredentials(baseUrl: _url.text, readToken: _token.text);

  Future<void> _run({required bool sync}) async {
    if (_busy || _loading) return;
    final connection = context.read<ConnectionProvider>();
    final teleprompter = context.read<TeleprompterProvider?>();
    final articles = context.read<ArticleProvider?>();
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      await _store.save(_credentials);
      if (!mounted) return;
      setState(() => _saved = true);
      if (!sync) {
        setState(() => _message = '连接配置已保存在本设备');
        return;
      }
      final result = await _service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
        teleprompter: teleprompter,
        allowedFromPage: widget.syncAllowed,
      );
      await articles?.loadArticles();
      if (mounted)
        setState(
          () => _message =
              '下载完成：新增 ${result.created} 篇，更新 ${result.updated} 篇，未变化 ${result.unchanged} 篇。可返回稿件列表独立提词。',
        );
    } catch (error) {
      if (mounted)
        setState(() {
          _message = error is CloudLibraryException
              ? error.message
              : '云稿库操作失败，请检查连接后重试';
          _error = true;
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    if (widget.syncService == null) _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectionProvider>();
    final teleprompter = context.watch<TeleprompterProvider?>();
    final local = connection.isLocal && connection.isConnected;
    final allowed = widget.syncAllowed && teleprompter?.isPlaying != true;
    final enabled = !_loading && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('下载云端新增和更新的稿件到本设备，随后离线独立提词。字号、透明度、语音模型和其他设备设置保持各自独立。'),
        const SizedBox(height: 16),
        TextField(
          key: const Key('cloud-library-url'),
          controller: _url,
          enabled: enabled,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '云稿库地址',
            hintText: 'https://你的服务地址/稿库路径',
          ),
          onChanged: (_) => setState(() => _saved = false),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('cloud-library-token'),
          controller: _token,
          enabled: enabled,
          obscureText: !_showToken,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '下载令牌',
            helperText: '仅保存在本设备连接配置中，不加入完整备份。',
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _showToken ? '隐藏下载令牌' : '显示下载令牌',
              onPressed: enabled
                  ? () => setState(() => _showToken = !_showToken)
                  : null,
              icon: Icon(
                _showToken
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          onChanged: (_) => setState(() => _saved = false),
        ),
        const SizedBox(height: 12),
        const Text(
          '同编号会更新已下载的云稿件，并覆盖该云稿正文的本地修改。本地其他稿件、稿件分组和提词设置不会被删除或覆盖。',
          style: TextStyle(fontSize: 12),
        ),
        if (!local) ...[
          const SizedBox(height: 12),
          const Text('请先断开远程播放服务端并切回本机服务端，再下载云端稿件。'),
        ],
        if (!allowed) ...[
          const SizedBox(height: 12),
          const Text('请先退出提词页面，再下载云端稿件。'),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(
            _message!,
            style: TextStyle(
              color: _error ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: enabled ? () => _run(sync: false) : null,
              child: Text(_saved ? '连接配置已保存' : '保存连接配置'),
            ),
            FilledButton.icon(
              onPressed: enabled && local && allowed
                  ? () => _run(sync: true)
                  : null,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined),
              label: Text(_busy ? '正在下载…' : '下载到本机'),
            ),
          ],
        ),
      ],
    );
  }
}

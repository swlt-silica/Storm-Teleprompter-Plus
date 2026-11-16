import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/article_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/folder_provider.dart';
import '../../providers/teleprompter_provider.dart';
import '../../services/cloud_library_service.dart';

enum _CloudOperation { save, upload, restore }

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
  final _readToken = TextEditingController();
  final _uploadToken = TextEditingController();
  late final _store = widget.store ?? CloudLibraryCredentialStore();
  late final _service = widget.syncService ?? CloudLibrarySyncService();
  bool _loading = true;
  bool _confirming = false;
  _CloudOperation? _operation;
  bool _showReadToken = false;
  bool _showUploadToken = false;
  bool _saved = false;
  String? _message;
  bool _error = false;

  bool get _busy => _operation != null;

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
      _readToken.text = credentials.readToken;
      _uploadToken.text = credentials.uploadToken;
      setState(() => _saved = credentials.baseUrl.isNotEmpty);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '连接配置读取失败，请重新填写';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  CloudLibraryCredentials get _credentials => CloudLibraryCredentials(
    baseUrl: _url.text,
    readToken: _readToken.text,
    uploadToken: _uploadToken.text,
  );

  Future<bool> _confirmOverwrite(_CloudOperation operation) async {
    final upload = operation == _CloudOperation.upload;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(upload ? '覆盖云端唯一备份？' : '整库恢复到本机？'),
            content: Text(
              upload
                  ? '将用本设备的全部稿件和文件夹覆盖云端唯一备份，不保留云端旧版本。其他设备尚未下载的云端稿件也会被替换。\n\n即使本机没有稿件和文件夹，上传也会清空云端稿库。字号、透明度、语音模型和连接令牌等设备设置不会上传。'
                  : '将用云端备份整库替换本机的全部稿件和文件夹，云端没有的本机稿件和文件夹会被删除。\n\n本机现有稿件不会另存为历史版本。字号、透明度、语音模型和连接令牌等设备设置保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('cloud-library-confirm-overwrite'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(upload ? '确认覆盖云端' : '确认替换本机稿库'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _run(_CloudOperation operation) async {
    if (_busy || _loading || _confirming) return;
    final connection = context.read<ConnectionProvider>();
    final teleprompter = context.read<TeleprompterProvider?>();
    final articles = context.read<ArticleProvider?>();
    final folders = context.read<FolderProvider?>();

    if (operation != _CloudOperation.save) {
      setState(() => _confirming = true);
      final confirmed = await _confirmOverwrite(operation);
      if (!mounted) return;
      setState(() => _confirming = false);
      if (!confirmed) return;
    }

    final credentials = _credentials;
    setState(() {
      _operation = operation;
      _message = null;
      _error = false;
    });
    try {
      await _store.save(credentials);
      if (!mounted) return;
      setState(() => _saved = true);
      if (operation == _CloudOperation.save) {
        setState(() => _message = '连接配置已保存在本设备');
        return;
      }
      if (operation == _CloudOperation.upload) {
        final result = await _service.uploadFromLocal(
          credentials: credentials,
          connection: connection,
          teleprompter: teleprompter,
          allowedFromPage: widget.syncAllowed,
        );
        if (mounted) {
          setState(
            () => _message =
                '上传完成：${result.articles} 篇稿件、${result.folders} 个文件夹。云端唯一备份已替换，其他设备可从云端整库恢复。',
          );
        }
      } else {
        final result = await _service.downloadToLocal(
          credentials: credentials,
          connection: connection,
          teleprompter: teleprompter,
          allowedFromPage: widget.syncAllowed,
        );
        if (!mounted) return;
        folders?.setCurrentFolder(null);
        await folders?.loadFolders();
        if (!mounted) return;
        await articles?.loadArticles();
        if (mounted) {
          setState(
            () => _message =
                '整库恢复完成：${result.articles} 篇稿件、${result.folders} 个文件夹。本机设备设置已保留，可返回稿件列表独立提词。',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error is CloudLibraryException
              ? error.message
              : '云稿库操作失败，请检查连接后重试';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _operation = null);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _readToken.dispose();
    _uploadToken.dispose();
    if (widget.syncService == null) _service.close();
    super.dispose();
  }

  Widget _actionIcon(_CloudOperation operation, IconData icon) =>
      _operation == operation
      ? const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon);

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectionProvider>();
    final teleprompter = context.watch<TeleprompterProvider?>();
    final local = connection.isLocal && connection.isConnected;
    final allowed = widget.syncAllowed && teleprompter?.isPlaying != true;
    final enabled = !_loading && !_busy && !_confirming;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '所有设备均可上传本机稿件和文件夹，或从云端整库恢复。云端只保留一份最新备份，每次上传都会覆盖；恢复后各设备仍可离线独立提词。',
        ),
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
          controller: _readToken,
          enabled: enabled,
          obscureText: !_showReadToken,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '下载令牌（可选）',
            helperText: '仅下载可填此项；留空时使用上传令牌下载。',
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _showReadToken ? '隐藏下载令牌' : '显示下载令牌',
              onPressed: enabled
                  ? () => setState(() => _showReadToken = !_showReadToken)
                  : null,
              icon: Icon(
                _showReadToken
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          onChanged: (_) => setState(() => _saved = false),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('cloud-library-upload-token'),
          controller: _uploadToken,
          enabled: enabled,
          obscureText: !_showUploadToken,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '上传令牌',
            helperText: '本设备需要上传时填写；两个令牌都只保存在本设备，不加入备份。',
            helperMaxLines: 3,
            suffixIcon: IconButton(
              tooltip: _showUploadToken ? '隐藏上传令牌' : '显示上传令牌',
              onPressed: enabled
                  ? () => setState(() => _showUploadToken = !_showUploadToken)
                  : null,
              icon: Icon(
                _showUploadToken
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          onChanged: (_) => setState(() => _saved = false),
        ),
        const SizedBox(height: 12),
        const Text(
          '上传替换云端全部稿件和文件夹，恢复替换本机全部稿件和文件夹。字号、透明度、语音模型、连接令牌和其他设备设置保持各自独立。',
          style: TextStyle(fontSize: 12),
        ),
        if (!local) ...[
          const SizedBox(height: 12),
          const Text('请先断开远程播放服务端并切回本机服务端，再上传或恢复云端稿库。'),
        ],
        if (!allowed) ...[
          const SizedBox(height: 12),
          const Text('请先退出提词页面，再上传或恢复云端稿库。'),
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
              key: const Key('cloud-library-save'),
              onPressed: enabled ? () => _run(_CloudOperation.save) : null,
              child: Text(
                _operation == _CloudOperation.save
                    ? '正在保存…'
                    : (_saved ? '连接配置已保存' : '保存连接配置'),
              ),
            ),
            FilledButton.icon(
              key: const Key('cloud-library-upload'),
              onPressed:
                  enabled &&
                      local &&
                      allowed &&
                      _uploadToken.text.trim().isNotEmpty
                  ? () => _run(_CloudOperation.upload)
                  : null,
              icon: _actionIcon(
                _CloudOperation.upload,
                Icons.cloud_upload_outlined,
              ),
              label: Text(
                _operation == _CloudOperation.upload ? '正在上传…' : '上传本机全部稿件',
              ),
            ),
            FilledButton.icon(
              key: const Key('cloud-library-restore'),
              onPressed: enabled && local && allowed
                  ? () => _run(_CloudOperation.restore)
                  : null,
              icon: _actionIcon(
                _CloudOperation.restore,
                Icons.cloud_download_outlined,
              ),
              label: Text(
                _operation == _CloudOperation.restore ? '正在整库恢复…' : '从云端整库恢复',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

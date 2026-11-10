import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';

class McpAccessController extends ChangeNotifier {
  new(
    this.createService, {
    this.createExtraHandlers,
    Future<Directory> Function()? supportDirectory,
    String? executable,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _executable =
           executable ??
           p.join(
             File(Platform.resolvedExecutable).parent.path,
             'ink_vault_mcp.exe',
           );

  final VaultMcpService Function() createService;
  final Map<String, VaultMcpHandler> Function()? createExtraHandlers;
  final Future<Directory> Function() _supportDirectory;
  final String _executable;
  VaultMcpBridge? _bridge;
  File? _file;
  var _disposed = false;
  Future<void>? _starting;
  var _generation = 0;
  bool get connected => _bridge != null;
  bool get writeEnabled => _bridge?.writeEnabled ?? false;

  Map<String, Object?> get clientConfiguration => {
    'mcpServers': {
      'personal-ink-vault': {
        'command': _executable,
        'args': ['--bridge-file', _file!.path],
      },
    },
  };

  Future<void> start() {
    if (_disposed) return Future.error(StateError('앱 연결 화면이 닫혔습니다.'));
    if (_bridge != null) return Future.value();
    if (_starting != null) return _starting!;
    late Future<void> pending;
    pending = _startBridge(_generation).whenComplete(() {
      if (identical(_starting, pending)) _starting = null;
    });
    _starting = pending;
    return pending;
  }

  Future<void> _startBridge(int generation) async {
    if (!File(_executable).existsSync()) {
      throw StateError('MCP 연결 도구가 없습니다. Windows 앱 전체 묶음을 설치하세요.');
    }
    final support = await _supportDirectory();
    if (_disposed || generation != _generation) return;
    _file = File(p.join(support.path, 'mcp', 'bridge.json'));
    final service = createService();
    final extraHandlers =
        createExtraHandlers?.call() ?? const <String, VaultMcpHandler>{};
    final bridge = await VaultMcpBridge.start(
      configFile: _file!,
      handler: (operation, arguments, context) =>
          extraHandlers[operation]?.call(operation, arguments, context) ??
          service.call(operation, arguments, context: context),
    );
    if (_disposed || generation != _generation) {
      await bridge.stop();
      return;
    }
    _bridge = bridge;
    notifyListeners();
  }

  Future<void> allowEdits(bool value) async {
    await _bridge?.setWriteEnabled(value);
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    _generation++;
    final pending = _starting;
    final bridge = _bridge;
    _bridge = null;
    await bridge?.stop();
    try {
      await pending;
    } catch (_) {
      /* A failed start cannot leave an active bridge. */
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop().catchError((Object _) {}));
    super.dispose();
  }
}

class McpPanel extends StatefulWidget {
  const new({super.key, required this.access});
  final McpAccessController access;
  @override
  State<McpPanel> createState() => _McpPanelState();
}

class _McpPanelState extends State<McpPanel> {
  var _busy = false;
  String? _error;
  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.access,
    builder: (context, _) {
      final access = widget.access;
      return AlertDialog(
        title: const Text('다른 AI 연결 · MCP'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('MCP를 지원하는 AI 앱에서 현재 저장소의 문서를 검색하고 읽거나 편집할 수 있습니다.'),
                const SizedBox(height: 12),
                const Text(
                  'Windows 앱이 열려 있는 동안 연결됩니다. 태블릿의 변경은 Drive로 이 PC에 수신된 뒤 접근할 수 있습니다.',
                ),
                const SizedBox(height: 16),
                Text(
                  access.connected ? '연결 켜짐' : '연결 꺼짐',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('AI의 문서 편집 허용'),
                  subtitle: const Text('변경 전 기준 버전을 확인하고 이전 내용을 이력에 보관합니다.'),
                  value: access.writeEnabled,
                  onChanged: _busy || !access.connected
                      ? null
                      : (value) => _perform(() => access.allowEdits(value)),
                ),
                if (access.connected) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '다른 AI 앱의 MCP 설정에 아래 내용을 추가하세요. 연결 비밀번호는 이 설정에 포함되지 않습니다.',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    const JsonEncoder.withIndent('  ')
                        .convert(access.clientConfiguration),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: const JsonEncoder.withIndent('  ')
                              .convert(access.clientConfiguration),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('연결 설정 복사'),
                  ),
                ],
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
          if (Platform.isWindows)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () =>
                        _perform(access.connected ? access.stop : access.start),
              child: Text(access.connected ? '연결 끄기' : '연결 켜기'),
            ),
        ],
      );
    },
  );
}

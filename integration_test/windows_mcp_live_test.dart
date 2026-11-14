import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/main.dart' as app;
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/windows_mcp_rpc.dart';

const _title = 'MCP 연결 시험 문서';
const _original = '# 연결 시험\n\n앱에서 저장한 첫 본문입니다.\n';
const _updated = '# 연결 시험\n\nMCP에서 바꾼 시험 본문입니다.\n';
const _denied = '# 거절되어야 할 변경\n';
final _panel = find.byType(McpPanel);
final _markdown = find.byType(MarkdownEditor);
final _source = find.descendant(
  of: _markdown,
  matching: find.byType(TextField),
);

Finder _inPanel(Finder child) => find.descendant(of: _panel, matching: child);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows app MCP permission, revision and live editor round trip',
    (tester) async {
      final run = await _OwnedRun.load();
      expect(defaultTargetPlatform, TargetPlatform.windows);
      PathProviderPlatform.instance = _RejectDefaultPaths();
      SharedPreferencesStorePlatform.instance = _RejectDefaultPreferences();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async =>
            throw StateError('Unexpected legacy secure storage access'),
      );
      final flow = _Flow(tester);
      WindowsMcpRpc? client;
      McpAccessController? access;
      final steps = <Map<String, Object?>>[];
      void record(String step, [Map<String, Object?> details = const {}]) =>
          steps.add({'step': step, ...details});
      try {
        await app.main(['--profile-directory', run.profile.path, '--verbose']);
        await flow.wait(
          'library loaded',
          () => find.byType(LibraryHome).evaluate().length == 1,
        );
        await flow.tap(
          find.byKey(const ValueKey('library-create-button')),
          'create menu',
        );
        await flow.tap(find.text('Markdown').last, 'create Markdown');
        final dialog = find.byType(AlertDialog);
        final name = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        await flow.wait('name dialog', () => name.evaluate().length == 1);
        await tester.enterText(name, _title);
        await flow.tap(
          find.descendant(of: dialog, matching: find.text('확인')),
          'confirm title',
        );
        await flow.tap(find.byTooltip('원문 편집'), 'edit Markdown source');
        await flow.wait('source field', () => _source.evaluate().length == 1);
        await tester.enterText(_source, _original);
        await flow.tap(find.byTooltip('기기에 저장'), 'save baseline');
        await flow.expectSource(_original);
        final mountedEditor = tester.state(_markdown);
        record('saved synthetic Markdown in the app');

        await flow.openPanel();
        access = tester.widget<McpPanel>(_panel).access;
        await flow.tap(_inPanel(find.text('연결 켜기')), 'connect MCP');
        await flow.wait('read-only MCP connected', () => flow.isEnabled(false));
        final configuration = access.clientConfiguration;
        final servers = configuration['mcpServers'] as Map;
        final server = servers['personal-ink-vault'] as Map;
        final command = server['command'] as String;
        final bridge = File(
          path.join(run.profile.path, 'support', 'mcp', 'bridge.json'),
        );
        expect(server.keys, unorderedEquals(['command', 'args']));
        expect(server['args'], ['--bridge-file', bridge.path]);
        expect(bridge.existsSync(), isTrue);
        expect(
          path.equals(
            path.dirname(command),
            path.dirname(Platform.resolvedExecutable),
          ),
          isTrue,
        );
        expect(path.basename(command), 'ink_vault_mcp.exe');
        final advertised = await WindowsMcpRpc.start(command, bridge.path);
        try {
          expect(
            _success(await advertised.call('vault_status', {}))['writeEnabled'],
            isFalse,
          );
          record('app-advertised MCP command connected', {
            'mcpPid': advertised.pid,
            'sha256': sha256
                .convert(await File(command).readAsBytes())
                .toString(),
          });
        } finally {
          await advertised.close();
        }
        expect(
          sha256.convert(await run.packagedMcp.readAsBytes()).toString(),
          run.mcpSha256,
        );
        client = await WindowsMcpRpc.start(run.packagedMcp.path, bridge.path);
        final tools = await client.tools();
        expect(
          tools,
          containsAll([
            'vault_status',
            'list_documents',
            'read_document',
            'update_document',
          ]),
        );
        expect(
          _success(await client.call('vault_status', {}))['writeEnabled'],
          isFalse,
        );
        final listed = _success(
          await client.call('list_documents', {'query': _title}),
        );
        final found = (listed['documents'] as List).single as Map;
        final noteId = found['noteId'] as String;
        final note = {'noteId': noteId};
        final before =
            _success(await client.call('read_document', note))['markdown']
                as Map;
        final beforeRevision = before['revisionId'] as String;
        expect(before['content'], _original);
        final revisionIdsBefore = await _markdownRevisions(client, note);
        expect(revisionIdsBefore, contains(beforeRevision));
        Map<String, Object?> update(String text, String revision) => {
          ...note,
          'target': 'markdown',
          'content': text,
          'expectedRevisionId': revision,
          'requestId': newId(),
        };
        _expectError(
          await client.call('update_document', update(_denied, beforeRevision)),
          'read_only',
        );
        record('external stdio read and default write denied', {
          'appPid': pid,
          'mcpPid': client.pid,
          'tools': tools.length,
          'mcpSha256': run.mcpSha256,
          'noteId': noteId,
          'baselineRevision': beforeRevision,
        });

        await flow.toggleEditing(true);
        expect(
          _success(await client.call('vault_status', {}))['writeEnabled'],
          isTrue,
        );
        await flow.closePanel();
        final request = update(_updated, beforeRevision);
        final edited = _success(await client.call('update_document', request));
        final afterRevision = edited['revisionId'] as String;
        expect(afterRevision, isNot(beforeRevision));
        await flow.expectSource(_updated);
        expect(identical(tester.state(_markdown), mountedEditor), isTrue);
        record('external write refreshed the already-open editor', {
          'revision': afterRevision,
        });
        expect(_success(await client.call('update_document', request)), edited);
        _expectError(
          await client.call('update_document', update(_denied, beforeRevision)),
          'revision_conflict',
        );
        final historical =
            _success(
                  await client.call('read_document', {
                    ...note,
                    'revisionId': beforeRevision,
                  }),
                )['revision']
                as Map;
        expect(historical['content'], _original);
        expect(await _markdownRevisions(client, note), {
          ...revisionIdsBefore,
          afterRevision,
        });
        record(
          'exact retry reused receipt, stale edit rejected, history preserved',
        );

        await flow.openPanel();
        await flow.toggleEditing(false);
        expect(
          _success(await client.call('vault_status', {}))['writeEnabled'],
          isFalse,
        );
        _expectError(
          await client.call('update_document', update(_denied, afterRevision)),
          'read_only',
        );
        final current =
            _success(await client.call('read_document', note))['markdown']
                as Map;
        expect(current['revisionId'], afterRevision);
        expect(current['content'], _updated);
        record('permission revoked while read access remained');
        await flow.tap(_inPanel(find.text('연결 끄기')), 'disconnect MCP');
        await flow.wait(
          'MCP disconnected',
          () =>
              _inPanel(find.text('연결 꺼짐')).evaluate().length == 1 &&
              !bridge.existsSync(),
        );
        _expectError(
          await client.call('read_document', note),
          'app_not_running',
        );
        record('bridge removed and existing client disconnected');
        await flow.closePanel();
        await flow.tap(find.byTooltip('문서 목록으로'), 'return to library');
        await flow.wait(
          'library returned',
          () => find.byType(LibraryHome).evaluate().length == 1,
        );
        final card = find.descendant(
          of: find.byType(LibraryHome),
          matching: find.text(_title),
        );
        await flow.tap(card, 'reopen updated Markdown');
        final sourceToggle = find.byTooltip('원문 편집');
        await flow.wait(
          'Markdown reopened',
          () =>
              _source.evaluate().length == 1 ||
              sourceToggle.evaluate().length == 1,
        );
        if (_source.evaluate().isEmpty)
          await flow.tap(sourceToggle, 'show reopened source');
        await flow.expectSource(_updated);
        record('saved revision reopened in the app', {
          'revision': afterRevision,
        });
        record('complete');
      } catch (error) {
        record('failed', {'error': error.toString()});
        rethrow;
      } finally {
        try {
          try {
            await client?.close();
          } finally {
            if (access?.connected ?? false) await access!.stop();
          }
        } finally {
          await File(path.join(run.evidence.path, 'steps.json')).writeAsString(
            const JsonEncoder.withIndent('  ').convert(steps),
            flush: true,
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Map<String, dynamic> _success(McpToolReply reply) {
  expect(reply.isError, isFalse, reason: reply.data['code'] as String?);
  return reply.data;
}

void _expectError(McpToolReply reply, String code) {
  expect(reply.isError, isTrue);
  expect(reply.data['code'], code);
}

Future<Set<String>> _markdownRevisions(
  WindowsMcpRpc client,
  Map<String, Object?> note,
) async {
  final response = _success(await client.call('list_revisions', note));
  return (response['revisions'] as List)
      .cast<Map<String, dynamic>>()
      .where((row) => row['kind'] == 'markdown')
      .map((row) => row['revisionId'] as String)
      .toSet();
}

class _Flow {
  new(this.tester);
  final WidgetTester tester;

  Future<void> wait(String step, bool Function() ready) async {
    final time = Stopwatch()..start();
    while (true) {
      await tester.pump(const Duration(milliseconds: 50));
      final error = tester.takeException();
      if (error != null) throw StateError('$step: $error');
      if (ready()) return;
      if (time.elapsed > const Duration(seconds: 20))
        throw StateError('$step timed out');
    }
  }

  Future<void> tap(Finder finder, String step) async {
    await wait(step, () => finder.evaluate().length == 1);
    await tester.ensureVisible(finder);
    await wait(
      '$step hit test',
      () => finder.hitTestable().evaluate().length == 1,
    );
    await tester.tap(finder);
  }

  Future<void> expectSource(String expected) =>
      wait('saved Markdown source', () {
        if (_markdown.evaluate().length != 1 || _source.evaluate().length != 1)
          return false;
        final editor = tester.widget<MarkdownEditor>(_markdown);
        return !editor.dirty &&
            editor.source == expected &&
            tester.widget<TextField>(_source).controller!.text == expected;
      });

  Future<void> openPanel() async {
    await tap(find.byTooltip('다른 AI 연결 · MCP'), 'open MCP panel');
    await wait('panel opened', () => _panel.evaluate().length == 1);
  }

  Future<void> closePanel() async {
    await tap(_inPanel(find.text('닫기')), 'close MCP panel');
    await wait('panel closed', () => _panel.evaluate().isEmpty);
  }

  Finder get _toggle => _inPanel(find.byType(SwitchListTile));

  bool isEnabled(bool value) {
    if (_toggle.evaluate().length != 1) return false;
    final toggle = tester.widget<SwitchListTile>(_toggle);
    return toggle.onChanged != null && toggle.value == value;
  }

  Future<void> toggleEditing(bool value) async {
    await wait('permission switch available', () => isEnabled(!value));
    await tap(_inPanel(find.text('AI의 문서 편집 허용')), 'toggle MCP write access');
    await wait('permission change saved', () => isEnabled(value));
  }
}

class _OwnedRun {
  new(this.profile, this.evidence, this.packagedMcp, this.mcpSha256);
  final Directory profile, evidence;
  final File packagedMcp;
  final String mcpSha256;

  static Future<_OwnedRun> load() async {
    const ownerPath = String.fromEnvironment('PIV_MCP_OWNER');
    const ownerSha = String.fromEnvironment('PIV_MCP_OWNER_SHA');
    final owner = File(ownerPath);
    final stage = owner.parent;
    if (!Platform.isWindows ||
        !path.isAbsolute(ownerPath) ||
        !RegExp(r'^wm1-[0-9a-f]{16}$').hasMatch(path.basename(stage.path)) ||
        !path.equals(stage.parent.path, r'E:\CodexBuilds\personal-ink-vault') ||
        !path.equals(await stage.resolveSymbolicLinks(), stage.path)) {
      throw StateError('Use the owned Windows MCP test launcher');
    }
    final bytes = await owner.readAsBytes();
    if (sha256.convert(bytes).toString() != ownerSha)
      throw StateError('MCP launch receipt changed');
    final config = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final profile = Directory(config['profile'] as String);
    final evidence = Directory(config['evidence'] as String);
    final packaged = File(config['packagedMcp'] as String);
    final extraction = packaged.parent;
    if (config['purpose'] != 'windows-app-mcp-live' ||
        !path.isWithin(stage.path, profile.path) ||
        !path.isWithin(stage.path, evidence.path) ||
        !path.equals(await profile.resolveSymbolicLinks(), profile.path) ||
        !path.equals(await evidence.resolveSymbolicLinks(), evidence.path) ||
        path.basename(packaged.path) != 'ink_vault_mcp.exe' ||
        path.basename(extraction.path) != 'extracted68-1' ||
        !RegExp(r'^w68-[0-9a-f]{16}$')
            .hasMatch(path.basename(extraction.parent.path)) ||
        !path.equals(extraction.parent.parent.path, stage.parent.path) ||
        !path.equals(await packaged.resolveSymbolicLinks(), packaged.path) ||
        !await profile.list().isEmpty ||
        !await evidence.list().isEmpty) {
      throw StateError(
        'MCP test requires a fresh isolated profile and evidence directory',
      );
    }
    return _OwnedRun(
      profile,
      evidence,
      packaged,
      config['mcpSha256'] as String,
    );
  }
}

class _RejectDefaultPaths extends PathProviderPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('App requested a default user directory');
}

class _RejectDefaultPreferences extends SharedPreferencesStorePlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'App requested default preferences: ${invocation.memberName}',
  );
}

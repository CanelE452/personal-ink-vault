import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';

import 'package:saber/data/drive/drive_connection.dart';

class DrivePanel extends StatefulWidget {
  final NoteRepository Function() repository;
  final Future<void> Function(NoteRepository) onRepositoryChanged;
  final Future<void> Function() onRemoteUpdated;
  final Future<void> Function() onResumeReload;
  const new({
    super.key,
    required this.repository,
    required this.onRepositoryChanged,
    required this.onRemoteUpdated,
    required this.onResumeReload,
  });
  @override
  State<DrivePanel> createState() => _DrivePanelState();
}

class _DrivePanelState extends State<DrivePanel> with WidgetsBindingObserver {
  late final DriveConnectionController controller;
  @override
  void initState() {
    super.initState();
    controller = DriveConnectionController(
      repository: () => widget.repository(),
      onRepositoryChanged: (next) => widget.onRepositoryChanged(next),
      onRemoteUpdated: () => widget.onRemoteUpdated(),
      onResumeReload: () => widget.onResumeReload(),
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      unawaited(controller.setForeground(true));
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached)
      unawaited(controller.setForeground(false));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(controller.close());
    super.dispose();
  }

  String get label {
    if (controller.error != null) return 'Drive 연결 확인 필요';
    if (!controller.ready || controller.busy) return 'Drive 준비 중';
    if (!controller.connected) return '기기에 저장됨 · Drive 미연결';
    return switch (controller.status.phase) {
      SyncPhase.idle => '기기에 저장됨',
      SyncPhase.pending => '업로드 대기',
      SyncPhase.syncing => 'Drive 송수신 중',
      SyncPhase.synced => 'Drive 반영 완료',
      SyncPhase.conflict => '충돌 확인 필요',
      SyncPhase.retryWaiting => '연결 복구 후 재시도',
      SyncPhase.authenticationRequired => 'Drive 재로그인 필요',
      SyncPhase.error => 'Drive 오류 · 기기 저장 유지',
      SyncPhase.closed => '기기에 저장됨',
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Tooltip(
      message: label,
      child: TextButton.icon(
        onPressed: controller.ready ? _open : null,
        icon: Icon(
          controller.connected
              ? Icons.cloud_done_outlined
              : Icons.cloud_off_outlined,
        ),
        label: Text(MediaQuery.sizeOf(context).width < 700 ? 'Drive' : label),
      ),
    ),
  );
  Future<void> _open() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => AlertDialog(
          title: const Text('Google Drive 동기화'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  const SizedBox(height: 12),
                  const Text(
                    '로컬 PDF·필기는 로그인 없이 저장됩니다. Drive 반영 완료는 다른 기기의 수신 완료를 뜻하지 않습니다.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isAndroid
                        ? 'Android 백그라운드 전송은 OS 실행 기회와 기존 인증에 따라 진행됩니다.'
                        : 'Windows는 앱이 실행 중일 때 동기화합니다.',
                  ),
                  if (controller.ready && controller.settings.folderId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(
                        'Drive 폴더 ID: ${controller.settings.folderId}',
                      ),
                    ),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        controller.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (controller.status.message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(controller.status.message!),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: controller.busy ? null : _configure,
                        child: const Text('OAuth 설정'),
                      ),
                      FilledButton(
                        onPressed: controller.busy ? null : controller.signIn,
                        child: const Text('Google 로그인 / 재연결'),
                      ),
                      OutlinedButton(
                        onPressed: controller.busy || !controller.signedIn
                            ? null
                            : controller.createCurrentVault,
                        child: const Text('현재 로컬 vault를 Drive에 만들기'),
                      ),
                      OutlinedButton(
                        onPressed: controller.busy || !controller.signedIn
                            ? null
                            : _chooseExisting,
                        child: const Text('기존 Drive vault 연결'),
                      ),
                      OutlinedButton(
                        onPressed: controller.busy || !controller.signedIn
                            ? null
                            : controller.retry,
                        child: const Text('지금 동기화 / 재시도'),
                      ),
                      TextButton(
                        onPressed: controller.busy ? null : controller.signOut,
                        child: const Text('Drive 연결 해제 · 로컬 자료 유지'),
                      ),
                      if (controller.busy && Platform.isWindows)
                        TextButton(
                          onPressed: controller.cancelSignIn,
                          child: const Text('로그인 취소'),
                        ),
                    ],
                  ),
                  if (controller.busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configure() async {
    final client = TextEditingController(
      text: Platform.isAndroid
          ? controller.settings.androidServerClientId
          : controller.settings.desktopClientId,
    );
    final secret = TextEditingController();
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Google Cloud OAuth 설정'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  Platform.isAndroid
                      ? '동일 Cloud 프로젝트의 Android 앱 등록과 Web OAuth client ID가 필요합니다. Web ID를 아래에 입력하세요.'
                      : '동일 Cloud 프로젝트의 Desktop app OAuth client ID를 입력하세요.',
                ),
                TextField(
                  controller: client,
                  decoration: const InputDecoration(
                    labelText: 'OAuth client ID (공개 식별자)',
                  ),
                ),
                if (Platform.isWindows)
                  TextField(
                    controller: secret,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Desktop client secret (선택, OS 보안 저장소)',
                      helperText: '빈 값은 기존 보안 저장 설정을 유지합니다.',
                    ),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '설정 절차: 저장소 docs/drive-setup.md. Client ID 변경 시 Drive 연결을 해제하며 로컬 노트는 보존합니다.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('설정 저장'),
            ),
          ],
        ),
      );
      if (save == true)
        await controller.configure(
          androidServerClientId: Platform.isAndroid
              ? client.text
              : controller.settings.androidServerClientId,
          desktopClientId: Platform.isWindows
              ? client.text
              : controller.settings.desktopClientId,
          desktopSecret: secret.text.isEmpty ? null : secret.text,
        );
    } finally {
      client.dispose();
      secret.dispose();
    }
  }

  Future<void> _chooseExisting() async {
    List<DriveVault> vaults = [];
    await controller.run(() async {
      vaults = await controller.listVaults();
    });
    if (!mounted || controller.error != null) return;
    final selected = await showDialog<DriveVault>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('기존 Drive vault 선택'),
        children: vaults.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '이 앱이 접근할 수 있는 vault가 없습니다. 같은 계정·Cloud 프로젝트·Drive 권한을 확인하세요.',
                  ),
                ),
              ]
            : vaults
                  .map(
                    (vault) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, vault),
                      child: Text('${vault.name}\n${vault.id}'),
                    ),
                  )
                  .toList(),
      ),
    );
    if (selected != null) await controller.connectExisting(selected);
  }
}

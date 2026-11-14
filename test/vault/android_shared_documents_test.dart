import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/imports/android_shared_documents.dart';
import 'package:saber/data/imports/shared_document_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/document_import');
  const id = '00000000-0000-4000-8000-000000000001';
  const path = '/data/user/0/vault/cache/intake/$id/Shared Slides.pptx';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'repeated native snapshots keep one lease until explicit release',
    () async {
      final inbox = SharedDocumentInbox();
      final released = Completer<void>();
      var nativeHasFile = true;
      var releaseCalls = 0;
      var arrivals = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'takePending':
            return nativeHasFile
                ? [
                    {'id': id, 'path': path},
                  ]
                : [];
          case 'release':
            expect(call.arguments, {'id': id});
            releaseCalls++;
            await released.future;
            nativeHasFile = false;
            return null;
          default:
            fail('Unexpected method ${call.method}');
        }
      });
      final bridge = AndroidSharedDocuments(
        inbox: inbox,
        onQueued: () => arrivals++,
        channel: channel,
      );
      addTearDown(() {
        if (!released.isCompleted) released.complete();
        bridge.dispose();
        inbox.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      bridge.start();
      await bridge.refresh();
      await bridge.refresh();
      expect(arrivals, 1);
      final owner = Object();
      final first = inbox.claim(owner: owner, scope: 'vault')!;
      inbox.finish(first, failure: StateError('temporary import failure'));
      await bridge.refresh();
      expect(releaseCalls, 0);
      expect(inbox.pending.single.id, first.request.id);
      expect(inbox.retry(first.request.id), isTrue);
      inbox.finish(inbox.claim(owner: owner, scope: 'vault')!);
      await bridge.refresh();
      expect(inbox.pending, isEmpty);
      expect(arrivals, 1);
      expect(releaseCalls, 1);
      released.complete();
      await bridge.refresh();
      expect(inbox.pending, isEmpty);
    },
  );

  test(
    'native envelopes with unsafe paths or unsupported types are ignored',
    () async {
      final inbox = SharedDocumentInbox();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          {'id': id, 'path': 'content://provider/file.pdf'},
          {'id': id, 'path': '/cache/intake/../file.docx'},
          {'id': id, 'path': '/cache/intake/file.exe'},
          {'id': 'not-an-id', 'path': path},
          {'id': id, 'path': path, 'extra': true},
        ],
      );
      final bridge = AndroidSharedDocuments(
        inbox: inbox,
        onQueued: () => fail('Unsafe input queued'),
        channel: channel,
      );
      addTearDown(() {
        bridge.dispose();
        inbox.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      await bridge.refresh();
      expect(inbox.pending, isEmpty);
    },
  );

  test(
    'the native warm-start signal collects files added after startup',
    () async {
      final inbox = SharedDocumentInbox();
      var available = false;
      final queued = Completer<void>();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => available
            ? [
                {'id': id, 'path': path},
              ]
            : [],
      );
      final bridge = AndroidSharedDocuments(
        inbox: inbox,
        onQueued: queued.complete,
        channel: channel,
      );
      addTearDown(() {
        bridge.dispose();
        inbox.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      bridge.start();
      await bridge.refresh();
      expect(inbox.pending, isEmpty);
      available = true;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('documentsChanged'),
        ),
        (_) {},
      );
      await queued.future;
      expect(inbox.pending.single.path, path);
    },
  );

  test('a recovered Android file waits for explicit vault selection', () async {
    final inbox = SharedDocumentInbox();
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => [
        {'id': id, 'path': path, 'recovered': true},
      ],
    );
    final bridge = AndroidSharedDocuments(
      inbox: inbox,
      onQueued: () {},
      channel: channel,
    );
    addTearDown(() {
      bridge.dispose();
      inbox.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await bridge.refresh();
    inbox.bindUnassigned('current-vault');
    final request = inbox.pending.single;
    expect(request.sharedRequestId, id);
    expect(request.needsDestinationConfirmation, isTrue);
    expect(inbox.claim(owner: Object(), scope: 'current-vault'), isNull);
    expect(inbox.useScope(request.id, 'current-vault'), isTrue);
    expect(
      inbox.claim(owner: Object(), scope: 'current-vault')?.request,
      same(request),
    );
  });
}

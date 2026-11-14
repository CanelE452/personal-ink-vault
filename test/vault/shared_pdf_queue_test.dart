import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/imports/shared_document_queue.dart';

void main() {
  test(
    'arrivals before a listener are retained in order with pending dedup',
    () {
      final inbox = SharedDocumentInbox();
      addTearDown(inbox.dispose);
      inbox.value = 'a.pdf';
      inbox.value = 'b.pdf';
      inbox.value = 'a.pdf';
      expect(inbox.pending.map((request) => request.path), ['a.pdf', 'b.pdf']);
      expect(inbox.value, 'b.pdf');
      final owner = Object();
      final a = inbox.claim(owner: owner, scope: 'vault')!;
      inbox.value = 'a.pdf';
      expect(inbox.pending, hasLength(2));
      expect(inbox.finish(a), true);
      final b = inbox.claim(owner: owner, scope: 'vault')!;
      expect(b.request.path, 'b.pdf');
      expect(inbox.finish(b), true);
      expect(inbox.value, isNull);
      inbox.value = 'a.pdf';
      final again = inbox.claim(owner: owner, scope: 'vault')!;
      expect(again.request.id, isNot(a.request.id));
    },
  );

  test('a stale completion cannot acknowledge the next owner request', () {
    final inbox = SharedDocumentInbox();
    addTearDown(inbox.dispose);
    inbox.value = 'a.pdf';
    inbox.value = 'b.pdf';
    final a = inbox.claim(owner: Object(), scope: 'vault')!;
    expect(inbox.claim(owner: Object(), scope: 'vault'), isNull);
    expect(inbox.finish(a), true);
    final b = inbox.claim(owner: Object(), scope: 'vault')!;
    expect(inbox.finish(a), false);
    expect(inbox.isCurrent(b), true);
    expect(inbox.pending.single.path, 'b.pdf');
  });

  test('clearing pending does not release an unsettled writer lease', () {
    final inbox = SharedDocumentInbox();
    addTearDown(inbox.dispose);
    inbox.value = 'old.pdf';
    final old = inbox.claim(owner: Object(), scope: 'old-vault')!;
    inbox.value = null;
    inbox.value = 'new.pdf';
    inbox.bindUnassigned('new-vault');
    expect(inbox.isCurrent(old), false);
    expect(inbox.claim(owner: Object(), scope: 'new-vault'), isNull);
    expect(inbox.finish(old), false);
    expect(inbox.pending.single.path, 'new.pdf');
    final next = inbox.claim(owner: Object(), scope: 'new-vault')!;
    expect(next.request.path, 'new.pdf');
  });

  test(
    'clearing pending retains the active staged file until its lease settles',
    () {
      final inbox = SharedDocumentInbox();
      addTearDown(inbox.dispose);
      final released = <String>[];
      inbox.enqueue('old.docx', onRelease: () async => released.add('old'));
      inbox.enqueue('other.pptx', onRelease: () async => released.add('other'));
      final old = inbox.claim(owner: Object(), scope: 'vault')!;
      inbox.value = null;
      expect(released, ['other']);
      expect(inbox.finish(old), isFalse);
      expect(released, ['other', 'old']);
    },
  );

  test('failed requests are held until explicit retry or deferral', () {
    final inbox = SharedDocumentInbox();
    addTearDown(inbox.dispose);
    inbox.value = 'a.pdf';
    inbox.value = 'b.pdf';
    final a = inbox.claim(owner: Object(), scope: 'vault')!;
    final failure = StateError('Preserve original');
    expect(inbox.finish(a, failure: failure), true);
    expect(inbox.pending.first.failure, same(failure));
    expect(inbox.claim(owner: Object(), scope: 'vault'), isNull);
    expect(inbox.retry(a.request.id), true);
    final retried = inbox.claim(owner: Object(), scope: 'vault')!;
    expect(retried.request.id, a.request.id);
    inbox.finish(retried, failure: failure);
    expect(inbox.defer(a.request.id), true);
    final b = inbox.claim(owner: Object(), scope: 'vault')!;
    expect(b.request.path, 'b.pdf');
  });

  test('binding does not silently retarget requests into another vault', () {
    final inbox = SharedDocumentInbox();
    addTearDown(inbox.dispose);
    inbox.value = 'a.pdf';
    inbox.bindUnassigned('old-vault');
    inbox.value = 'b.pdf';
    inbox.bindUnassigned('new-vault');
    expect(inbox.pending.first.scope, 'old-vault');
    expect(inbox.pending.last.scope, 'new-vault');
    expect(inbox.claim(owner: Object(), scope: 'new-vault'), isNull);
    final id = inbox.pending.first.id;
    expect(inbox.useScope(id, 'new-vault'), true);
    final moved = inbox.claim(owner: Object(), scope: 'new-vault')!;
    expect(moved.request.id, id);
  });

  test('an active scope cannot be rebound or deferred by another owner', () {
    final inbox = SharedDocumentInbox();
    addTearDown(inbox.dispose);
    inbox.value = 'a.pdf';
    final a = inbox.claim(owner: Object(), scope: 'old-vault')!;
    expect(inbox.useScope(a.request.id, 'new-vault'), false);
    expect(inbox.defer(a.request.id), false);
    expect(inbox.retry(a.request.id), false);
    expect(inbox.isCurrent(a), true);
    expect(a.request.scope, 'old-vault');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_registry.dart';

class _Probe extends AppActionRegistry {
  new({super.parent});
  bool get listened => hasListeners;
}

void main() {
  final runs = <String>[];
  setUp(runs.clear);

  AppAction a(
    String id, {
    String? label,
    bool enabled = true,
    bool? checked,
    Key? key,
    String? tag,
  }) => AppAction(
    id: id,
    label: label ?? id,
    icon: KitIconName.more,
    run: (_) => runs.add(tag ?? id),
    enabled: enabled,
    checked: checked,
    widgetKey: key,
  );

  final owner = Object();

  testWidgets('resolve keeps order and drops unknown ids', (tester) async {
    final r = AppActionRegistry()
      ..publish(owner, [a('insertPage'), a('export')]);
    expect(r.resolve(['export', 'nope', 'insertPage']).map((x) => x.id), [
      'export',
      'insertPage',
    ]);
    r.dispose();
  });

  testWidgets('lookup falls back to the parent and the child wins', (
    tester,
  ) async {
    final app = AppActionRegistry()
      ..publish(Object(), [a('mcp'), a('openSettings')]);
    final doc = AppActionRegistry(parent: app)
      ..publish(Object(), [a('openSettings', label: '문서')]);
    expect(doc.lookup('mcp'), isNotNull);
    expect(doc.lookup('openSettings')!.label, '문서');
    expect(app.lookup('openSettings')!.label, 'openSettings');
    expect(app.has('undo'), isFalse);
    expect(doc.has('mcp'), isTrue);
    doc.dispose();
    app.dispose();
  });

  testWidgets('publish replaces the whole list of that owner', (tester) async {
    final r = AppActionRegistry()..publish(owner, [a('undo'), a('redo')]);
    expect(r.has('redo'), isTrue);
    r.publish(owner, [a('undo')]);
    expect(r.has('redo'), isFalse);
    expect(r.has('undo'), isTrue);
    r.dispose();
  });

  testWidgets(
    'a new owner takes an id over and the old owner withdraw keeps it',
    (tester) async {
      final oldEditor = Object();
      final newEditor = Object();
      final r = AppActionRegistry()
        ..publish(oldEditor, [a('undo', tag: 'old')])
        ..publish(newEditor, [a('undo', tag: 'new')])
        ..withdraw(oldEditor);
      expect(r.has('undo'), isTrue);
      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      expect(r.run('undo', context), isTrue);
      expect(runs, ['new']);
      r.withdraw(newEditor);
      expect(r.has('undo'), isFalse);
      r.dispose();
    },
  );

  testWidgets('notifies once after the frame and only when the look changes', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final r = AppActionRegistry();
    var n = 0;
    r.addListener(() => n++);

    r.publish(owner, [a('undo')]);
    await tester.pump();
    expect(n, 1, reason: 'new id');

    r.publish(owner, [a('undo', enabled: false)]);
    r.publish(owner, [a('undo', enabled: true, checked: true)]);
    expect(n, 1, reason: 'not before the frame');
    await tester.pump();
    expect(n, 2, reason: 'two publishes in one frame, one notice');

    r.publish(owner, [a('undo', enabled: true, checked: true)]);
    await tester.pump();
    expect(n, 2, reason: 'same look');

    r.publish(owner, [a('undo', enabled: true, checked: true, tag: 'other')]);
    await tester.pump();
    expect(n, 2, reason: 'only run changed');
    final context = tester.element(find.byType(SizedBox));
    r.run('undo', context);
    expect(runs, ['other']);

    r.publish(owner, [a('undo', enabled: true, checked: true), a('redo')]);
    await tester.pump();
    expect(n, 3, reason: 'id added');

    r.withdraw(owner);
    await tester.pump();
    expect(n, 4, reason: 'withdrawn');

    r.withdraw(owner);
    await tester.pump();
    expect(n, 4, reason: 'nothing left to withdraw');
    r.dispose();
  });

  testWidgets('no notice after dispose', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final r = AppActionRegistry();
    var n = 0;
    r.addListener(() => n++);
    r.publish(owner, [a('undo')]);
    r.dispose();
    await tester.pump();
    expect(n, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('publishing inside build does not throw', (tester) async {
    final r = AppActionRegistry();
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          ListenableBuilder(
            listenable: r,
            builder: (_, _) => Text(
              r.has('undo') ? 'has' : 'none',
              textDirection: TextDirection.ltr,
            ),
          ),
          Builder(
            builder: (_) {
              r.publish(owner, [a('undo')]);
              return const SizedBox();
            },
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('has'), findsOneWidget);
    r.dispose();
  });

  testWidgets('parent changes reach the child and dispose detaches', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final app = _Probe();
    final doc = _Probe(parent: app);
    var n = 0;
    doc.addListener(() => n++);
    app.publish(owner, [a('mcp')]);
    await tester.pump();
    expect(n, 1);
    expect(app.listened, isTrue);
    doc.dispose();
    expect(app.listened, isFalse);
    app.dispose();
  });

  testWidgets('scope of() rebuilds dependents and read() does not', (
    tester,
  ) async {
    final r = AppActionRegistry();
    var ofBuilds = 0;
    var readBuilds = 0;
    await tester.pumpWidget(
      AppActionScope(
        actions: r,
        child: Column(
          textDirection: TextDirection.ltr,
          children: [
            Builder(
              builder: (c) {
                ofBuilds++;
                AppActionScope.of(c);
                return const SizedBox();
              },
            ),
            Builder(
              builder: (c) {
                readBuilds++;
                expect(AppActionScope.read(c), same(r));
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    expect(ofBuilds, 1);
    expect(readBuilds, 1);
    r.publish(owner, [a('undo')]);
    await tester.pump(); // the notice comes after this frame
    await tester.pump(); // the rebuild it asked for
    expect(ofBuilds, 2);
    expect(readBuilds, 1);
    r.dispose();
  });

  testWidgets('scope read() is null without a scope', (tester) async {
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          expect(AppActionScope.read(c), isNull);
          return const SizedBox();
        },
      ),
    );
  });

  testWidgets('run calls only enabled actions', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final r = AppActionRegistry()
      ..publish(owner, [a('undo'), a('redo', enabled: false)]);
    expect(r.run('undo', context), isTrue);
    expect(runs, ['undo']);
    expect(r.run('redo', context), isFalse);
    expect(r.run('nope', context), isFalse);
    expect(runs, ['undo']);
    r.dispose();
  });

  test('an unknown id is an assertion error in debug', () {
    final r = AppActionRegistry();
    expect(() => r.publish(owner, [a('nope')]), throwsA(isA<AssertionError>()));
  });

  test('looksSame ignores run only', () {
    expect(a('undo').looksSame(a('undo', tag: 'x')), isTrue);
    expect(a('undo').looksSame(a('undo', label: 'x')), isFalse);
    expect(a('undo').looksSame(a('undo', checked: false)), isFalse);
    expect(a('undo').looksSame(a('undo', key: const Key('k'))), isFalse);
  });

  testWidgets('debugPublishedIds keeps each owner list, also a taken-over id', (
    tester,
  ) async {
    final first = Object(), second = Object();
    final r = AppActionRegistry()
      ..publish(first, [a('undo'), a('redo')])
      ..publish(second, [a('undo'), a('save')]);
    // The table holds one owner for undo; the record still shows both.
    expect(r.debugPublishedIds[first], {'undo', 'redo'});
    expect(r.debugPublishedIds[second], {'undo', 'save'});
    r.publish(first, [a('redo')]);
    expect(r.debugPublishedIds[first], {'redo'});
    r.withdraw(second);
    expect(r.debugPublishedIds.keys, [first]);
    r.dispose();
  });
}

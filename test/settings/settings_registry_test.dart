import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/korean_particle.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stow/stow.dart';
import 'package:stow_plain/stow_plain.dart';

ToggleSetting toggle(
  String key,
  String label, {
  List<String> conflicts = const [],
  bool on = false,
  String group = '시험',
  String? description,
  ValueNotifier<bool>? notifier,
}) => ToggleSetting(
  key: key,
  label: label,
  description: description,
  group: group,
  notifier: notifier ?? ValueNotifier(on),
  conflictsWith: conflicts,
);

void main() {
  late ValueNotifier<Map<String, String>> reasons;
  late SettingsRegistry reg;

  setUp(() {
    reasons = ValueNotifier<Map<String, String>>({});
    reg = SettingsRegistry(reasons: reasons);
  });

  group('with the table disposed by the test', () {
    setUp(() => addTearDown(reg.dispose));

    test('particle follows the final consonant', () {
      expect(subjectParticle('손가락 필기'), '가');
      expect(subjectParticle('세로 스크롤'), '이');
      expect(subjectParticle('PDF'), '이(가)');
      expect(subjectParticle(''), '이(가)');
    });

    test('writing a value directly turns its partner off with a reason', () {
      final a = toggle('a', '시험 하나', conflicts: ['b']);
      final b = toggle('b', '시험 둘');
      reg
        ..register(a)
        ..register(b);
      b.notifier.value = true;
      a.notifier.value = true;
      expect(b.notifier.value, isFalse);
      expect(reg.autoOffReason('b'), '시험 하나가 켜져 있어서 꺼졌습니다');
    });

    test('conflicts declared on one side work both ways', () {
      final a = toggle('a', '시험 하나', conflicts: ['b']);
      final b = toggle('b', '시험 둘');
      reg
        ..register(a)
        ..register(b);
      a.notifier.value = true;
      b.notifier.value = true;
      expect(a.notifier.value, isFalse);
      expect(b.notifier.value, isTrue);
      expect(reg.autoOffReason('a'), '시험 둘이 켜져 있어서 꺼졌습니다');
    });

    test('turning the partner back on clears its reason', () {
      final a = toggle('a', '시험 하나', conflicts: ['b']);
      final b = toggle('b', '시험 둘');
      reg
        ..register(a)
        ..register(b);
      b.notifier.value = true;
      a.notifier.value = true;
      expect(reg.autoOffReason('b'), isNotNull);
      b.notifier.value = true;
      expect(reg.autoOffReason('b'), isNull);
      expect(a.notifier.value, isFalse);
      expect(reg.autoOffReason('a'), '시험 둘이 켜져 있어서 꺼졌습니다');
    });

    test('no cascade, and registering changes nothing', () {
      final a = toggle('a', '시험 하나', conflicts: ['b']);
      final b = toggle('b', '시험 둘', conflicts: ['c'], on: true);
      final c = toggle('c', '시험 셋', on: true);
      reg
        ..register(a)
        ..register(b)
        ..register(c);
      expect(b.notifier.value, isTrue);
      expect(c.notifier.value, isTrue);
      expect(reasons.value, isEmpty);
      a.notifier.value = true;
      expect(b.notifier.value, isFalse);
      expect(reg.autoOffReason('b'), '시험 하나가 켜져 있어서 꺼졌습니다');
      expect(c.notifier.value, isTrue);
      expect(reg.autoOffReason('c'), isNull);
    });

    test('only the partners of the row turned on change', () {
      final a = toggle('a', '시험 하나', conflicts: ['b']);
      final b = toggle('b', '시험 둘', on: true);
      final c = toggle('c', '시험 셋', conflicts: ['d']);
      final d = toggle('d', '시험 넷', on: true);
      reg
        ..register(a)
        ..register(b)
        ..register(c)
        ..register(d);
      // Some other code reacts to b going off by turning c on.
      b.notifier.addListener(() {
        if (!b.notifier.value) c.notifier.value = true;
      });
      a.notifier.value = true;
      expect(a.notifier.value, isTrue);
      expect(b.notifier.value, isFalse);
      expect(reg.autoOffReason('b'), '시험 하나가 켜져 있어서 꺼졌습니다');
      expect(c.notifier.value, isTrue);
      expect(d.notifier.value, isTrue);
      expect(reg.autoOffReason('d'), isNull);
    });

    test('a stored reason shows only while its row is off', () {
      const r = '시험 하나가 켜져 있어서 꺼졌습니다';
      reasons.value = {'b': r, 'c': r};
      reg
        ..register(toggle('b', '시험 둘'))
        ..register(toggle('c', '시험 셋', on: true));
      expect(reg.autoOffReason('b'), r);
      expect(reg.autoOffReason('c'), isNull);
      expect(reg.autoOffReason('missing'), isNull);
    });

    test('registering the same key again replaces the row and its watcher', () {
      final oldA = ValueNotifier(false);
      final newA = ValueNotifier(false);
      final b = toggle('b', '시험 둘');
      reg
        ..register(toggle('a', '시험 하나', conflicts: ['b'], notifier: oldA))
        ..register(b)
        ..register(toggle('a', '시험 하나', conflicts: ['b'], notifier: newA));
      expect(reg.entries.length, 2);
      expect(reg.entries.first.key, 'a');
      b.notifier.value = true;
      oldA.value = true;
      expect(b.notifier.value, isTrue);
      newA.value = true;
      expect(b.notifier.value, isFalse);
    });

    test('search ignores spaces and case and reads descriptions', () {
      reg
        ..register(toggle('a', '손가락 필기'))
        ..register(toggle('b', 'PDF 내보내기'))
        ..register(toggle('c', '압력', description: '펜 굵기에 반영'));
      expect(reg.search('손가락필기').map((e) => e.key), ['a']);
      expect(reg.search('pdf').map((e) => e.key), ['b']);
      expect(reg.search('굵기').map((e) => e.key), ['c']);
      expect(reg.search('').map((e) => e.key), ['a', 'b', 'c']);
      expect(reg.search('없는말'), isEmpty);
    });

    test('groups keep registration order', () {
      reg
        ..register(toggle('a', 'A', group: '필기'))
        ..register(toggle('b', 'B', group: '보관함'))
        ..register(toggle('c', 'C', group: '필기'));
      expect(reg.groups, ['필기', '보관함']);
      expect(reg.inGroup('필기').map((e) => e.key), ['a', 'c']);
      expect(reg.byKey('b')?.label, 'B');
      expect(reg.byKey('zzz'), isNull);
    });

    test('entries cannot be edited from outside', () {
      reg.register(toggle('a', 'A'));
      expect(() => reg.entries.add(toggle('x', 'X')), throwsUnsupportedError);
    });
  });

  test('dispose stops the pair rule', () {
    final a = toggle('a', '시험 하나', conflicts: ['b']);
    final b = toggle('b', '시험 둘');
    reg
      ..register(a)
      ..register(b);
    reg.dispose();
    b.notifier.value = true;
    a.notifier.value = true;
    expect(a.notifier.value, isTrue);
    expect(b.notifier.value, isTrue);
    reasons.value = {'x': 'y'};
  });

  test('clear() takes the reasons out with the rows', () {
    addTearDown(reg.dispose);
    final a = toggle('a', '시험 하나', conflicts: ['b']);
    final b = toggle('b', '시험 둘');
    reg
      ..register(a)
      ..register(b);
    b.notifier.value = true;
    a.notifier.value = true;
    expect(reasons.value, isNotEmpty);
    reg.clear();
    expect(reg.entries, isEmpty);
    expect(reasons.value, isEmpty);
  });

  test('stored reasons decode to Map<String, String>', () {
    FlavorConfig.setup();
    addTearDown(reg.dispose);
    final codec = stows.settingsAutoOffReasons.codec!;
    final back = codec.decode(codec.encode({'b': '시험 하나가 켜져 있어서 꺼졌습니다'}));
    expect(back, isA<Map<String, String>>());
    expect(back, {'b': '시험 하나가 켜져 있어서 꺼졌습니다'});
  });

  group('storage', () {
    setUp(() {
      Stow.volatileInTests = false;
      SharedPreferences.setMockInitialValues({'testA': true, 'testB': true});
    });
    tearDown(() => Stow.volatileInTests = true);

    test('values read from storage do not turn partners off', () async {
      addTearDown(reg.dispose);
      final a = PlainStow('testA', false);
      final b = PlainStow('testB', false);
      reg
        ..register(
          ToggleSetting(
            key: 'testA',
            label: '시험 하나',
            group: '시험',
            notifier: a,
            conflictsWith: const ['testB'],
          ),
        )
        ..register(
          ToggleSetting(key: 'testB', label: '시험 둘', group: '시험', notifier: b),
        );
      await a.waitUntilRead();
      await b.waitUntilRead();
      expect(a.value, isTrue);
      expect(b.value, isTrue);
      expect(reg.autoOffReason('testA'), isNull);
      expect(reg.autoOffReason('testB'), isNull);
      expect(reasons.value, isEmpty);
    });
  });
}

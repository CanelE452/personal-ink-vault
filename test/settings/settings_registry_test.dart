import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/korean_particle.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/setting_rule.dart';
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

  group('rules', () {
    setUp(() => addTearDown(reg.dispose));

    test(
      'a Requires row is unusable while its toggle is off, with its reason',
      () {
        // `needs` is a row that is not a stow
        final needs = toggle('straightLineInHand', '펜마다 직선');
        reg
          ..register(needs)
          ..register(toggle('axis', '수평/수직'))
          ..addRule(
            const Requires(
              key: 'axis',
              needs: 'straightLineInHand',
              reason: '먼저 직선을 켜세요.',
            ),
          );
        expect(reg.unusableReason('axis'), '먼저 직선을 켜세요.');
        expect(reg.unusableReason('straightLineInHand'), isNull);
        needs.notifier.value = true;
        expect(reg.unusableReason('axis'), isNull);
        needs.notifier.value = false;
        expect(reg.unusableReason('axis'), '먼저 직선을 켜세요.');
        expect(reg.unusableReason('none'), isNull);
      },
    );

    test("a value given for the needed row counts in place of the row's", () {
      final needs = toggle('straightLineInHand', '펜마다 직선');
      reg
        ..register(needs)
        ..addRule(
          const Requires(
            key: 'axis',
            needs: 'straightLineInHand',
            reason: '먼저 직선을 켜세요.',
          ),
        );
      // a pen window's own pen in hand, apart from the table's row
      expect(
        reg.unusableReason('axis', values: {'straightLineInHand': true}),
        isNull,
      );
      needs.notifier.value = true;
      expect(
        reg.unusableReason('axis', values: {'straightLineInHand': false}),
        '먼저 직선을 켜세요.',
      );
      // without the row in the table the given value still counts
      final bare = SettingsRegistry(reasons: ValueNotifier({}))
        ..addRule(
          const Requires(
            key: 'axis',
            needs: 'straightLineInHand',
            reason: '먼저 직선을 켜세요.',
          ),
        );
      addTearDown(bare.dispose);
      expect(bare.unusableReason('axis'), isNull);
      expect(
        bare.unusableReason('axis', values: {'straightLineInHand': false}),
        '먼저 직선을 켜세요.',
      );
    });

    test(
      'KeepOneOn.lists refuses to turn the last item off across its lists',
      () {
        final a = ValueNotifier<List<String>>(['pen', 'pencil']);
        final b = ValueNotifier<List<String>>(['tape']);
        reg
          ..register(
            ListSetting(key: 'la', label: 'A', group: '시험', notifier: a),
          )
          ..register(
            ListSetting(key: 'lb', label: 'B', group: '시험', notifier: b),
          )
          ..addRule(
            const KeepOneOn.lists(keys: ['la', 'lb'], reason: '하나는 남겨요.'),
          );
        // three on in all: none is the last
        expect(reg.keepOneReason('la', item: 'pen'), isNull);
        expect(reg.keepOneReason('lb', item: 'tape'), isNull);
        a.value = ['pen'];
        expect(reg.keepOneReason('la', item: 'pen'), isNull);
        b.value = [];
        expect(reg.keepOneReason('la', item: 'pen'), '하나는 남겨요.');
        // an item that is off is never held
        expect(reg.keepOneReason('la', item: 'pencil'), isNull);
        // only the shown items count
        a.value = ['pen', 'pencil'];
        expect(reg.keepOneReason('la', item: 'pen'), isNull);
        expect(
          reg.keepOneReason('la', item: 'pen', among: ['pen']),
          '하나는 남겨요.',
        );
        expect(reg.keepOneText('lb'), '하나는 남겨요.');
        expect(reg.keepOneText('other'), isNull);
      },
    );

    test('KeepOneOn.lists reads each list through its own reader, fallback included', () {
      // `la` is stored empty and falls back to its reader's value
      final a = ValueNotifier<List<String>>([]);
      final b = ValueNotifier<List<String>>([]);
      var fallback = ['pen'];
      reg
        ..register(
          ListSetting(
            key: 'la',
            label: 'A',
            group: '시험',
            notifier: a,
            read: () => a.value.isEmpty ? fallback : a.value,
          ),
        )
        ..register(ListSetting(key: 'lb', label: 'B', group: '시험', notifier: b))
        ..addRule(
          const KeepOneOn.lists(keys: ['la', 'lb'], reason: '하나는 남겨요.'),
        );
      // the fallback's one item is the true last one
      expect(reg.keepOneReason('la', item: 'pen'), '하나는 남겨요.');
      // another list has one on: nothing is refused
      b.value = ['tape'];
      expect(reg.keepOneReason('la', item: 'pen'), isNull);
      expect(reg.keepOneReason('lb', item: 'tape'), isNull);
      // two on in the first list: not the last
      a.value = ['pen', 'pencil'];
      b.value = [];
      expect(reg.keepOneReason('la', item: 'pen'), isNull);
      // the other list holds the last one
      a.value = [];
      b.value = ['tape'];
      fallback = [];
      expect(reg.keepOneReason('lb', item: 'tape'), '하나는 남겨요.');
      // shown names filter the union
      a.value = ['pen', 'pencil'];
      expect(
        reg.keepOneReason('la', item: 'pen', among: ['pen', 'pencil']),
        isNull,
      );
      expect(
        reg.keepOneReason('la', item: 'pen', among: ['pen', 'tape']),
        isNull,
      );
      b.value = [];
      expect(reg.keepOneReason('la', item: 'pen', among: ['pen']), '하나는 남겨요.');
    });

    test('KeepOneOn.toggles refuses to turn the last toggle off', () {
      final a = toggle('a', 'A', on: true);
      final b = toggle('b', 'B', on: true);
      reg
        ..register(a)
        ..register(b)
        ..addRule(
          const KeepOneOn.toggles(keys: ['a', 'b'], reason: '하나는 켜 두세요.'),
        );
      expect(reg.keepOneReason('a'), isNull);
      b.notifier.value = false;
      expect(reg.keepOneReason('a'), '하나는 켜 두세요.');
      expect(reg.keepOneReason('b'), isNull);
      expect(reg.keepOneReason('a', among: ['a', 'b']), '하나는 켜 두세요.');
    });

    test('rows with onPage false are not listed for the page', () {
      ToggleSetting hidden(String key, String label, String group) =>
          ToggleSetting(
            key: key,
            label: label,
            group: group,
            onPage: false,
            notifier: ValueNotifier(false),
          );
      reg
        ..register(toggle('shown', '보이는 줄', group: '필기'))
        ..register(hidden('hidden', '숨은 줄', '필기'))
        ..register(toggle('only', '다른 줄', group: '보관함'))
        ..register(hidden('hidden2', '숨은 모임 줄', '숨은 모임'));
      expect(reg.entries.map((e) => e.key), ['shown', 'only']);
      expect(reg.groups, ['필기', '보관함']);
      expect(reg.inGroup('필기').map((e) => e.key), ['shown']);
      expect(reg.search('숨은'), isEmpty);
      expect(reg.byKey('hidden'), isNotNull);
    });
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

  test('a row that owns its notifier lets it go with the row and the table', () {
    bool disposed(ChangeNotifier n) {
      try {
        ChangeNotifier.debugAssertNotDisposed(n);
        return false;
      } on FlutterError {
        return true;
      }
    }

    ToggleSetting owned(String key, ValueNotifier<bool> n, {bool page = true}) =>
        ToggleSetting(
          key: key,
          label: key,
          group: 'g',
          onPage: page,
          notifier: n,
          ownsNotifier: true,
        );
    final a = ValueNotifier(false), b = ValueNotifier(false);
    final c = ValueNotifier(false), kept = ValueNotifier(false);
    addTearDown(kept.dispose);
    reg.register(owned('a', a));
    // replaced in place: the old one goes
    reg.register(owned('a', b));
    expect(disposed(a), isTrue);
    expect(disposed(b), isFalse);
    // the same notifier registered again stays
    reg.register(owned('a', b));
    expect(disposed(b), isFalse);
    // taken off the page
    reg.clear();
    expect(disposed(b), isTrue);
    reg
      ..register(owned('c', c, page: false))
      ..register(toggle('k', 'k', notifier: kept));
    reg.clear();
    expect(disposed(c), isFalse);
    reg.dispose();
    expect(disposed(c), isTrue);
    // a row that does not own its notifier leaves it
    expect(disposed(kept), isFalse);
  });
}

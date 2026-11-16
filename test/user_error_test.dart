import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/user_error_text.dart';
import 'package:saber/data/user_error.dart';

void main() {
  test('user error messages keep Korean sentences and hide developer text', () {
    expect(
      userErrorMessage(
        PlatformException(
          code: 'office_reopen_cancelled',
          message: '필기용 PDF를 마치지 못했습니다.',
        ),
      ),
      '필기용 PDF를 마치지 못했습니다.',
    );
    expect(
      userErrorMessage(PlatformException(code: 'x')),
      '작업을 마치지 못했습니다.',
    );
    expect(
      userErrorMessage(StateError('보관함 내용이 바뀌었습니다.')),
      '보관함 내용이 바뀌었습니다.',
    );
    expect(userErrorMessage(Exception('원본 파일이 없습니다.')), '원본 파일이 없습니다.');
    expect(
      userErrorMessage(
        const FormatException('변환한 PDF를 열 수 없습니다. 다시 시도해 주세요.'),
      ),
      '변환한 PDF를 열 수 없습니다. 다시 시도해 주세요.',
    );
    expect(userErrorMessage(const FormatException('')), '파일 내용을 읽지 못했습니다.');
    expect(
      userErrorMessage(
        const FileSystemException('Cannot open file', '/data/user/0/x/a.pdf'),
      ),
      'Cannot open file',
    );
    expect(
      userErrorMessage(const FileSystemException('', '/data/user/0/x/a.pdf')),
      '파일을 읽거나 쓰지 못했습니다.',
    );
    expect(
      userErrorMessage(TimeoutException(null)),
      '시간 안에 끝나지 않았습니다. 다시 시도해 주세요.',
    );
    expect(userErrorMessage('이미 열려 있습니다.'), '이미 열려 있습니다.');
    expect(userErrorMessage(ArgumentError('bad')), '작업을 마치지 못했습니다.');
    // Messages stay visible; only the developer wrapping and internal paths go.
    expect(
      userErrorMessage(Exception('synthetic flush failure')),
      'synthetic flush failure',
    );
    expect(userErrorMessage(StateError('No element')), 'No element');
    expect(
      userErrorMessage(
        PlatformException(
          code: 'x',
          message: 'com.google.android.gms.common.api.ApiException: 7: ',
        ),
      ),
      '작업을 마치지 못했습니다.',
    );
    expect(
      userErrorMessage(StateError('저장하지 못했습니다: /data/user/0/io/x')),
      '저장하지 못했습니다',
    );
    expect(
      userErrorMessage('1개 이동 완료 · 1개 미처리. Bad state: 문서가 바뀌었습니다'),
      '1개 이동 완료 · 1개 미처리. 문서가 바뀌었습니다',
    );
    expect(
      userErrorMessage(
        '실패: PlatformException(office_x, 필기용 PDF를 마치지 못했습니다., null, null)',
      ),
      '실패: 필기용 PDF를 마치지 못했습니다.',
    );
    expect(
      userErrorDetails(
        PlatformException(code: 'office_reopen_cancelled', message: 'm'),
      ),
      contains('office_reopen_cancelled'),
    );
  });

  testWidgets(
    'UserErrorText shows the sentence and hides the raw error until 자세히',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UserErrorText(
              message: '필기용 PDF를 마치지 못했습니다.',
              details: 'PlatformException(office_reopen_cancelled, null)',
            ),
          ),
        ),
      );
      expect(find.text('필기용 PDF를 마치지 못했습니다.'), findsOneWidget);
      expect(find.textContaining('PlatformException'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('user-error-details')));
      await tester.pump();
      expect(find.textContaining('PlatformException'), findsOneWidget);
    },
  );

  testWidgets('error snackbar shows the sentence and closes on its own', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUserErrorSnackBar(
                context,
                PlatformException(
                  code: 'office_reopen_cancelled',
                  message: '필기용 PDF를 마치지 못했습니다.',
                ),
              ),
              child: const Text('fail'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('fail'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.text('필기용 PDF를 마치지 못했습니다.'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse);
    await tester.tap(find.text('자세히'));
    await tester.pumpAndSettle();
    expect(find.textContaining('office_reopen_cancelled'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
  });
}

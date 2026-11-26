import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/planner/google_calendar.dart';

final _log = Logger('PIVError');

const _generic = '작업을 마치지 못했습니다.';

/// `PlatformException(code, message, details, stacktrace)` written into a text: keeps the message.
final _platformWrapper = RegExp(r'PlatformException\([^,]*, ([^,]*)(?:, [^)]*)?\)');

/// Dart's error prefixes: "Bad state: ", "Exception: ", "FormatException: ", "SomethingError: "…
final _typePrefix = RegExp(
  r'(?:Bad state|(?:[A-Za-z_]\w*\.)*(?:[A-Z]?[A-Za-z]*Exception|[A-Z][A-Za-z]*Error)): ',
);

/// A message needs at least one word to be worth showing.
final _word = RegExp('[A-Za-z가-힣]');

/// App-internal paths a user cannot open.
final _internalPath = RegExp(
  r'(?:/data/(?:user|data)/|/storage/emulated/|[A-Za-z]:\\)\S*',
);

/// Removes the developer wrapping from [text] and keeps its message.
String _clean(String text) => text
    .replaceAllMapped(_platformWrapper, (match) => match[1]!)
    .replaceAll(_typePrefix, '')
    .replaceAll(_internalPath, '')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .replaceAll(RegExp(r'\s*:\s*$'), '')
    .trim();

/// The text a user sees for [error]: its message without the developer
/// wrapping (exception names, "Bad state:", `PlatformException(…, null,
/// null)`) and without app-internal paths. The app throws its own Korean
/// sentences in all of these types, so a fixed sentence is used only when the
/// message is empty, and for Dart programming errors. The original stays in
/// [userErrorDetails] and the log.
String userErrorMessage(Object error) {
  final text = switch (error) {
    final String text => text,
    final PlatformException e => e.message,
    final StateError e => e.message,
    final FormatException e => e.message,
    final FileSystemException e => e.message,
    final TimeoutException e => e.message,
    CalendarApiException() || SocketException() || HandshakeException() => null,
    Error() => null,
    _ => '$error',
  };
  final cleaned = text == null ? '' : _clean(text);
  if (_word.hasMatch(cleaned) && !cleaned.startsWith('Instance of ')) {
    return cleaned;
  }
  return switch (error) {
    FormatException() => '파일 내용을 읽지 못했습니다.',
    FileSystemException() => '파일을 읽거나 쓰지 못했습니다.',
    TimeoutException() => '시간 안에 끝나지 않았습니다. 다시 시도해 주세요.',
    SocketException() || HandshakeException() =>
      '인터넷에 연결하지 못했습니다. 연결을 확인한 뒤 다시 시도해 주세요.',
    CalendarApiException(status: 401 || 403) =>
      'Google 캘린더 연결이 만료되었거나 권한이 없습니다. 설정에서 다시 연결해 주세요.',
    CalendarApiException(status: 429 || >= 500) =>
      'Google 캘린더 서버가 응답하지 않습니다. 잠시 뒤 다시 시도해 주세요.',
    CalendarApiException() => 'Google 캘린더와 동기화하지 못했습니다.',
    _ => _generic,
  };
}

/// The original error, for the "자세히" view.
String userErrorDetails(Object error) => '$error';

/// Keeps the original error in the app log (it reaches logcat in release).
void logUserError(Object error, [StackTrace? stackTrace]) =>
    _log.warning(userErrorMessage(error), error, stackTrace);

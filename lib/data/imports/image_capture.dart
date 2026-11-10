import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class ImageCaptureCapabilities {
  const new({required this.available, this.reason});
  final bool available;
  final String? reason;
}

class ImageCaptureException implements Exception {
  const new(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

class NativeImageCapture {
  const new({
    this.channel = const MethodChannel('personal_ink_vault/camera'),
    this.platform,
  });
  final MethodChannel channel;
  final TargetPlatform? platform;

  bool get _isAndroid =>
      !kIsWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.android;

  Future<ImageCaptureCapabilities> capabilities() async {
    if (!_isAndroid)
      return const ImageCaptureCapabilities(
        available: false,
        reason: '이 기기에서는 사진 촬영을 지원하지 않습니다.',
      );
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      return ImageCaptureCapabilities(
        available: result?['available'] == true,
        reason: result?['reason'] as String?,
      );
    } on MissingPluginException {
      return const ImageCaptureCapabilities(
        available: false,
        reason: '카메라 기능이 설치되지 않았습니다.',
      );
    } on PlatformException catch (error) {
      return ImageCaptureCapabilities(
        available: false,
        reason: error.message ?? '카메라 앱을 사용할 수 없습니다.',
      );
    }
  }

  Future<File?> capture() async {
    final support = await capabilities();
    if (!support.available)
      throw ImageCaptureException(
        'unavailable',
        support.reason ?? '카메라 앱을 사용할 수 없습니다.',
      );
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('capture');
      if (result == null) return null;
      final path = result['path'];
      if (path is! String ||
          path.isEmpty ||
          !p.posix.isAbsolute(path) ||
          path.contains('\u0000')) {
        throw const ImageCaptureException(
          'invalid_response',
          '촬영한 사진의 위치를 확인하지 못했습니다.',
        );
      }
      return File(path);
    } on MissingPluginException {
      throw const ImageCaptureException('unavailable', '카메라 기능이 설치되지 않았습니다.');
    } on PlatformException catch (error) {
      throw ImageCaptureException(
        error.code,
        error.message ?? '사진 촬영을 완료하지 못했습니다.',
      );
    }
  }
}

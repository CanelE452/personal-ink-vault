import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

class InkVaultNativeException implements Exception {
  const new(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'InkVaultNativeException($code): $message';
}

class InkVaultNative {
  factory open({String? libraryPath}) {
    final path = libraryPath ?? _packagedLibraryPath();
    try {
      return InkVaultNative._(DynamicLibrary.open(path));
    } on Object {
      throw const InkVaultNativeException(
        'library_unavailable',
        'The common engine could not be loaded. Rebuild the native library or reinstall the application.',
      );
    }
  }

  new _(DynamicLibrary library)
    : _request = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('ink_vault_request'),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('ink_vault_free'),
      _version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'ink_vault_version',
          );

  final Pointer<Utf8> Function(Pointer<Utf8>) _request;
  final void Function(Pointer<Utf8>) _free;
  final Pointer<Utf8> Function() _version;

  static String _packagedLibraryPath() {
    if (Platform.isWindows) {
      return p.join(
        File(Platform.resolvedExecutable).parent.path,
        'ink_vault_native.dll',
      );
    }
    if (Platform.isAndroid || Platform.isLinux) return 'libink_vault_native.so';
    throw const InkVaultNativeException(
      'platform_unsupported',
      'The common engine is unavailable on this platform.',
    );
  }

  String get version => _version().toDartString();

  Map<String, dynamic> invoke(Map<String, Object?> request) {
    final input = jsonEncode(request).toNativeUtf8(allocator: calloc);
    Pointer<Utf8> output = nullptr;
    try {
      output = _request(input);
      if (output == nullptr) {
        throw const InkVaultNativeException(
          'invalid_response',
          'The common engine returned no response.',
        );
      }
      final decoded = jsonDecode(output.toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw const InkVaultNativeException(
          'invalid_response',
          'The common engine returned an invalid response.',
        );
      }
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        throw InkVaultNativeException(
          error['code'] as String,
          error['message'] as String,
        );
      }
      return decoded;
    } finally {
      if (output != nullptr) _free(output);
      calloc.free(input);
    }
  }
}

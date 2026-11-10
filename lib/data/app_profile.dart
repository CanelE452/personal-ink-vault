import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

class AppStartupOptions {
  const new _(this.verbose, this.profileDirectory);

  factory parse(List<String> args) {
    final parser = ArgParser()
      ..addFlag('verbose', abbr: 'v', negatable: false)
      ..addOption('profile-directory');
    final parsed = parser.parse(args);
    final selected = parsed.option('profile-directory');
    if (selected != null && (selected.isEmpty || !path.isAbsolute(selected))) {
      throw const FormatException('Profile directory must be an absolute path');
    }
    return AppStartupOptions._(
      parsed.flag('verbose'),
      selected == null ? null : Directory(path.normalize(selected)),
    );
  }

  final bool verbose;
  final Directory? profileDirectory;
}

Future<void> configureAppProfile(Directory? directory) async {
  if (directory == null) return;
  if (!Platform.isWindows) {
    throw UnsupportedError('Explicit app profiles are supported on Windows');
  }
  if (!path.isAbsolute(directory.path)) {
    throw const FormatException('Profile directory must be an absolute path');
  }

  final root = Directory(path.normalize(directory.path));
  final support = Directory(path.join(root.path, 'support'));
  await support.create(recursive: true);
  final preferences = await _ProfilePreferences.open(
    File(path.join(support.path, 'shared_preferences.json')),
  );
  final paths = _ProfilePaths(root);
  for (final name in ['documents', 'cache', 'temp', 'downloads']) {
    await Directory(path.join(root.path, name)).create(recursive: true);
  }

  PathProviderPlatform.instance = paths;
  SharedPreferencesStorePlatform.instance = preferences;
}

class _ProfilePaths extends PathProviderPlatform {
  new(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async =>
      path.join(root.path, 'support');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      path.join(root.path, 'documents');

  @override
  Future<String?> getApplicationCachePath() async =>
      path.join(root.path, 'cache');

  @override
  Future<String?> getTemporaryPath() async => path.join(root.path, 'temp');

  @override
  Future<String?> getDownloadsPath() async => path.join(root.path, 'downloads');
}

class _ProfilePreferences extends SharedPreferencesStorePlatform {
  new(this.file, this._values);

  final File file;
  Map<String, Object> _values;
  var _pending = Future<void>.value();

  static Future<_ProfilePreferences> open(File file) async {
    final values = <String, Object>{};
    if (file.existsSync()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Profile preferences must be a JSON object',
        );
      }
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is bool || value is int || value is String) {
          values[entry.key] = value;
        } else if (value is double && value.isFinite) {
          values[entry.key] = value;
        } else if (value is List && value.every((item) => item is String)) {
          values[entry.key] = List<String>.from(value);
        } else {
          throw const FormatException('Unsupported profile preference value');
        }
      }
    }
    return _ProfilePreferences(file, values);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final valid = switch (valueType) {
      'Bool' => value is bool,
      'Int' => value is int,
      'Double' => value is double && value.isFinite,
      'String' => value is String,
      'StringList' => value is List<String>,
      _ => false,
    };
    if (!valid) {
      return Future<bool>.error(ArgumentError('Invalid preference value type'));
    }
    final saved = _copy(value);
    return _change((values) => values[key] = saved);
  }

  @override
  Future<bool> remove(String key) => _change((values) => values.remove(key));

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final prefix = parameters.filter.prefix;
    final allowed = parameters.filter.allowList?.toSet();
    return _change(
      (values) => values.removeWhere(
        (key, _) =>
            key.startsWith(prefix) &&
            (allowed == null || allowed.contains(key)),
      ),
    );
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final prefix = parameters.filter.prefix;
    final allowed = parameters.filter.allowList?.toSet();
    await _pending;
    return {
      for (final entry in _values.entries)
        if (entry.key.startsWith(prefix) &&
            (allowed == null || allowed.contains(entry.key)))
          entry.key: _copy(entry.value),
    };
  }

  Future<bool> _change(void Function(Map<String, Object>) change) {
    final operation = _pending.then((_) async {
      final next = Map<String, Object>.from(_values);
      change(next);
      final encoded = jsonEncode(next);
      final pendingFile = File('${file.path}.pending');
      await pendingFile.writeAsString(encoded, flush: true);
      await pendingFile.rename(file.path);
      _values = next;
      return true;
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Object _copy(Object value) =>
      value is List<String> ? List<String>.from(value) : value;
}

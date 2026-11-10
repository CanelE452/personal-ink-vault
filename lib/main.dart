import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:printing/printing.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/app_profile.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/imports/android_shared_documents.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/data/sentry/sentry_init.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/logs.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:window_manager/window_manager.dart';
import 'package:worker_manager/worker_manager.dart';

Future<void> main(List<String> args) async {
  final options = AppStartupOptions.parse(args);
  WidgetsFlutterBinding.ensureInitialized();
  await configureAppProfile(options.profileDirectory);

  /// To set the flavor config e.g. for the Play Store, use:
  /// flutter build \
  ///   --dart-define=FLAVOR="Google Play" \
  ///   --dart-define=APP_STORE="Google Play" \
  ///   --dart-define=UPDATE_CHECK="false"
  FlavorConfig.setupFromEnvironment();

  await initSentry(() => appRunner(options));
}

Future<void> appRunner(AppStartupOptions options) async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = (kDebugMode || options.verbose)
      ? Level.INFO
      : Level.WARNING;
  Logger.root.onRecord.listen((record) {
    logsHistory.add(record);

    if (!isSentryEnabled) {
      // ignore: avoid_print
      print('${record.level.name}: ${record.loggerName}: ${record.message}');
    }
  });

  // For some reason, logging errors breaks hot reload while debugging.
  if (!kDebugMode && !isSentryEnabled) {
    final errorLogger = Logger('ErrorLogger');
    FlutterError.onError = (details) {
      errorLogger.severe(
        details.exceptionAsString(),
        details.exception,
        details.stack,
      );
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      errorLogger.severe(error, stackTrace);
      // Returns false in debug mode so the error is printed to stderr
      return !kDebugMode;
    };
  }

  StrokeOptionsExtension.setDefaults();
  Stows.markAsOnMainIsolate();

  await Future.wait([
    stows.customDataDir.waitUntilRead().then((_) => FileManager.init()),
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      windowManager.ensureInitialized(),
    workerManager.init(
      // Fewer isolates in debug mode to avoid slowing down hot reload
      isolatesCount: kDebugMode ? 1 : 2,
    ),
    stows.locale.waitUntilRead(),
    PencilShader.init(),
    Printing.info().then((info) {
      Editor.canRasterPdf = info.canRaster;
    }),
  ]);

  setLocale();
  stows.locale.addListener(setLocale);
  stows.customDataDir.addListener(FileManager.migrateDataDir);
  pdfrxFlutterInitialize();

  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['ink_vault_native (Rust)'],
      await rootBundle.loadString(
        'packages/ink_vault_native/THIRD_PARTY_LICENSES.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks(
      const ['ink_hwp_native (Rust)'],
      await rootBundle.loadString(
        'packages/ink_hwp_native/THIRD_PARTY_LICENSES.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks(
      const ['ink_vault_mcp (Rust)'],
      await rootBundle.loadString(
        'packages/ink_vault_mcp/THIRD_PARTY_LICENSES.txt',
      ),
    );
    yield LicenseEntryWithLineBreaks(const [
      'Noto Sans CJK KR',
    ], await rootBundle.loadString('build/native/fonts/OFL.txt'));
    for (final licenseFile in const [
      'assets/google_fonts/Atkinson_Hyperlegible_Next/OFL.txt',
      'assets/google_fonts/Dekko/OFL.txt',
      'assets/google_fonts/Fira_Mono/OFL.txt',
      'assets/google_fonts/Neucha/OFL.txt',
    ]) {
      final license = await rootBundle.loadString(licenseFile);
      yield LicenseEntryWithLineBreaks(const ['google_fonts'], license);
    }
  });

  runApp(SentryWidget(child: TranslationProvider(child: const App())));
}

void setLocale() {
  if (stows.locale.value.isNotEmpty &&
      AppLocaleUtils.supportedLocalesRaw.contains(stows.locale.value)) {
    LocaleSettings.setLocaleRaw(stows.locale.value);
  } else {
    LocaleSettings.useDeviceLocale();
  }
}

class const App({super.key}) extends StatefulWidget {
  static final log = Logger('App');

  static var initialLocation = '/workspace';
  static final _router = GoRouter(
    initialLocation: initialLocation,
    routes: <GoRoute>[
      GoRoute(path: '/', redirect: (context, state) => initialLocation),
      GoRoute(
        path: '/workspace',
        builder: (context, state) => const StudyWorkspace(enableDrive: true),
      ),
      GoRoute(
        path: RoutePaths.home,
        redirect: (context, state) => initialLocation,
      ),
      GoRoute(
        path: RoutePaths.edit,
        redirect: (context, state) => initialLocation,
      ),
      GoRoute(
        path: RoutePaths.login,
        redirect: (context, state) => initialLocation,
      ),
      GoRoute(path: '/profile', redirect: (context, state) => RoutePaths.login),
      GoRoute(
        path: RoutePaths.logs,
        builder: (context, state) => const LogsPage(),
      ),
    ],
  );

  static void openFile(SharedFile file) async {
    final filePath = file.value;
    if (file.type != SharedMediaType.FILE || filePath == null) return;
    if (filePath.toLowerCase().endsWith('.pdf')) {
      StudyWorkspace.pendingDocumentImport.value = filePath;
      _router.go(initialLocation);
    } else {
      log.warning('이 공유 경로의 파일 형식은 지원하지 않습니다.');
    }
  }

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  StreamSubscription? _intentDataStreamSubscription;
  AndroidSharedDocuments? _androidDocuments;
  AppLifecycleListener? _documentLifecycle;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      final documents = AndroidSharedDocuments(
        inbox: StudyWorkspace.pendingDocumentImport,
        onQueued: () => App._router.go(App.initialLocation),
      );
      _androidDocuments = documents;
      _documentLifecycle = AppLifecycleListener(onResume: documents.refresh);
      documents.start();
    }
    setupSharingIntent();
  }

  void setupSharingIntent() {
    if (Platform.isAndroid || Platform.isIOS) {
      // for files opened while the app is closed
      FlutterSharingIntent.instance.getInitialSharing().then((
        List<SharedFile> files,
      ) {
        for (final file in files) {
          App.openFile(file);
        }
      });

      // for files opened while the app is open
      final stream = FlutterSharingIntent.instance.getMediaStream();
      _intentDataStreamSubscription = stream.listen((List<SharedFile> files) {
        for (final file in files) {
          App.openFile(file);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DynamicMaterialApp(title: 'Personal Ink Vault', router: App._router);
  }

  @override
  void dispose() {
    _documentLifecycle?.dispose();
    _androidDocuments?.dispose();
    _intentDataStreamSubscription?.cancel();
    super.dispose();
  }
}

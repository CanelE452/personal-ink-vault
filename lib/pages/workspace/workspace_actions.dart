part of 'study_workspace.dart';

/// The workspace's app level actions: what the settings page's rows run, and
/// what the library's gear opens. Published again on every build, so each one
/// shows the current state (busy, connected, desktop).
extension _WorkspaceAppActions on _StudyWorkspaceState {
  void _publishAppActions(WorkspaceController c) {
    final mcp = _mcp;
    final ready = !busy && !c.externalBusy;
    final desktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    _appActions.publish(this, [
      AppAction(
        id: AppActionIds.openSettings,
        label: '설정',
        icon: KitIconName.settings,
        enabled: !busy,
        run: (_) {
          if (!mounted) return;
          unawaited(
            Navigator.of(context).push(appSettingsRoute(actions: _appActions)),
          );
        },
      ),
      AppAction(
        id: AppActionIds.localVaults,
        label: '기기의 저장소',
        icon: KitIconName.folder,
        enabled: !busy,
        run: (_) => unawaited(_run(_localVaults)),
      ),
      AppAction(
        id: AppActionIds.backup,
        label: '백업 내보내기',
        icon: KitIconName.upload,
        enabled: !busy,
        run: (_) => unawaited(_run(_backup)),
      ),
      AppAction(
        id: AppActionIds.restore,
        label: '별도 저장소로 복원',
        icon: KitIconName.history,
        enabled: !busy,
        run: (_) => unawaited(_run(_restore)),
      ),
      AppAction(
        id: AppActionIds.vaultExport,
        label: 'Obsidian 보관함 ZIP',
        icon: KitIconName.folder,
        enabled: ready && c.native != null,
        widgetKey: const ValueKey('workspace-vault-export'),
        run: (_) => unawaited(_run(_exportObsidianVault)),
      ),
      if (mcp != null)
        AppAction(
          id: AppActionIds.mcp,
          label: '다른 AI 연결 · MCP',
          icon: KitIconName.ai,
          run: (_) {
            if (!mounted) return;
            unawaited(
              showDialog<void>(
                context: context,
                builder: (_) => McpPanel(access: mcp),
              ),
            );
          },
        ),
      AppAction(
        id: AppActionIds.openNoteLink,
        label: '노트 링크 열기',
        icon: KitIconName.open,
        run: (_) => unawaited(
          _run(() async {
            final link = await _input('inkvault 링크 열기', '');
            if (link != null) await _openLink(link);
          }),
        ),
      ),
      AppAction(
        id: AppActionIds.viewLogs,
        label: '기록 보기',
        icon: KitIconName.doc,
        run: (_) {
          if (mounted) unawaited(context.push(RoutePaths.logs));
        },
      ),
      if (desktop)
        AppAction(
          id: AppActionIds.openDataDir,
          label: '데이터 폴더 열기',
          icon: KitIconName.open,
          run: (_) {
            final tool = Platform.isWindows
                ? 'explorer'
                : Platform.isLinux
                ? 'xdg-open'
                : 'open';
            unawaited(Process.run(tool, [FileManager.documentsDirectory]));
          },
        ),
    ]);
  }

  /// The open document's actions this screen offers, in the editor host's
  /// registry beside the editor's (the shortcuts of 229's function row). The
  /// app's (MCP, 노트 링크 열기, 보관함 ZIP) stay in the app registry.
  void _publishDocumentActions(
    WorkspaceController c,
    NoteSession session, {
    required bool sideBySide,
  }) {
    final repository = c.repository;
    final kind = session.note.documentKind;
    final idle = !busy && !c.externalBusy;
    final pdfCanvas = kind == VaultDocumentKind.pdf && _pdfCanvasVisible();
    final canvasExport = kind == VaultDocumentKind.canvas;
    final formats = <(PortableExportFormat, String)>[
      if (kind == VaultDocumentKind.page ||
          kind == VaultDocumentKind.database) ...[
        (PortableExportFormat.markdown, 'Markdown'),
        (PortableExportFormat.html, 'HTML'),
        if (kind == VaultDocumentKind.database)
          (PortableExportFormat.csv, 'CSV'),
        (PortableExportFormat.pdf, 'PDF'),
      ],
    ];
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository) &&
        identical(c.activeSession, session);
    // From 더 많은 기능 the document may have changed while the menu was open.
    void guarded(VoidCallback action) {
      if (current()) action();
    }

    void run(Future<void> Function() operation) {
      if (current()) unawaited(_run(operation));
    }

    void export(Future<void> Function() operation) {
      if (current() && !busy && !c.externalBusy) unawaited(_run(operation));
    }

    // the open ink note's ⋯ 「읽기 전용」
    bool inkLocked() => _editorChrome.editor?.inkLocked.value ?? false;

    final (viewLabel, viewIcon) = switch (kind) {
      VaultDocumentKind.page => ('페이지', KitIconName.doc),
      VaultDocumentKind.database => ('데이터베이스', KitIconName.draw),
      VaultDocumentKind.canvas => ('캔버스', KitIconName.draw),
      _ => ('PDF·필기', KitIconName.draw),
    };

    _editorChrome.actions.publish(this, [
      // The infinite note's 손가락 필기, the editor's setting: its bar has no
      // ⋯, so the row's ⋯ shows it (the ink editor publishes its own).
      if (kind == VaultDocumentKind.infinite)
        AppAction(
          id: AppActionIds.finger,
          label: '손가락 필기',
          icon: KitIconName.tap,
          checked: stows.editorFingerDrawing.value,
          run: (_) => stows.editorFingerDrawing.value =
              !stows.editorFingerDrawing.value,
        ),
      AppAction(
        id: AppActionIds.prev,
        label: '이전 위치',
        icon: KitIconName.back,
        enabled: idle && c.navigation.peekBack != null,
        run: (_) => run(() => _history(forward: false)),
      ),
      AppAction(
        id: AppActionIds.next,
        label: '다음 위치',
        icon: KitIconName.chevR,
        enabled: idle && c.navigation.peekForward != null,
        run: (_) => run(() => _history(forward: true)),
      ),
      AppAction(
        id: AppActionIds.save,
        label: '기기에 저장',
        icon: KitIconName.download,
        run: (_) => run(_save),
      ),
      if (pdfCanvas)
        AppAction(
          id: AppActionIds.pdfSearch,
          label: 'PDF 본문 검색',
          icon: KitIconName.search,
          enabled: !busy && c.canSearchPdfText(session),
          run: (_) =>
              guarded(() => unawaited(_showPdfTextSearch(c, session))),
        ),
      if (canvasExport || formats.isNotEmpty)
        AppAction(
          id: AppActionIds.documentExport,
          label: '문서 내보내기',
          icon: KitIconName.upload,
          enabled: idle,
          widgetKey: const ValueKey('portable-export-menu'),
          // The formats open on the button (or ⋯) that called it.
          run: (context) => _showMenuOn(context, [
            if (canvasExport)
              PopupMenuItem<void>(
                onTap: () => export(_exportObsidianCanvas),
                child: const Text('Obsidian Canvas ZIP'),
              ),
            for (final (format, label) in formats)
              PopupMenuItem<void>(
                onTap: () => export(() => _exportDocument(format)),
                child: Text(label),
              ),
          ]),
        ),
      // The note and its Markdown; the button shows the other view.
      if (kind != VaultDocumentKind.markdown && !sideBySide)
        AppAction(
          id: AppActionIds.viewToggle,
          label: markdownTab ? viewLabel : 'Markdown',
          icon: markdownTab ? viewIcon : KitIconName.textTt,
          widgetKey: const ValueKey('note-view-toggle'),
          run: (_) => _toggleMarkdownTab(),
        ),
      if (pdfCanvas && _keepsOriginal(c, session))
        AppAction(
          id: AppActionIds.pdfRemake,
          label: '새 엔진으로 PDF 다시 만들기',
          icon: KitIconName.refresh,
          enabled: idle,
          widgetKey: const ValueKey('pdf-remake-from-original'),
          run: (_) => run(() => _remakePdfFromOriginal(c, session)),
        ),
      // The editor toolbar's ⋯ 「이름 바꾸기」: the library's rename of this note.
      AppAction(
        id: AppActionIds.rename,
        label: '이름 바꾸기',
        icon: KitIconName.rename,
        enabled: idle,
        run: (_) =>
            run(() => _noteAction(session.note, LibraryNoteAction.rename)),
      ),
      // ⋯ 「휴지통으로」: the library's 휴지통 for this note (saved first);
      // the trashed note's tab goes. Not while the note is 읽기 전용: the
      // ⋯ menu dims the row, and the action refuses (this screen does not
      // rebuild when the lock changes, so [AppAction.enabled] cannot say it).
      AppAction(
        id: AppActionIds.moveToTrash,
        label: '휴지통으로',
        icon: KitIconName.trash,
        enabled: idle,
        run: (_) {
          if (inkLocked()) return;
          run(() => _noteAction(session.note, LibraryNoteAction.trash));
        },
      ),
      // ⋯ 「보기」: the function row's 「탭 줄 보이기」 brings it back too.
      AppAction(
        id: AppActionIds.tabBarHide,
        label: '탭 줄 숨기기',
        icon: KitIconName.noteTab,
        checked: stows.noteTabBarHidden.value,
        run: (_) => stows.noteTabBarHidden.value = !stows.noteTabBarHidden.value,
      ),
      AppAction(
        id: AppActionIds.quickSwitch,
        label: '빠른 문서 전환',
        icon: KitIconName.swap,
        enabled: idle,
        widgetKey: const ValueKey('workspace-quick-switch'),
        run: (_) => guarded(_quickSwitch),
      ),
      if (repository.formatVersion >= 2)
        AppAction(
          id: AppActionIds.bookmarks,
          label: '북마크',
          icon: KitIconName.bookmark,
          enabled: idle,
          widgetKey: const ValueKey('workspace-bookmarks'),
          run: (_) => guarded(() => unawaited(_bookmarks())),
        ),
      if (c.native != null)
        AppAction(
          id: AppActionIds.knowledge,
          label: '문서 연결 · 태그 · 그래프',
          icon: KitIconName.book,
          enabled: !busy,
          run: (_) => guarded(() => unawaited(_knowledge())),
        ),
      if (!c.pdfPeerPreview)
        AppAction(
          id: AppActionIds.copyPageLink,
          label: '현재 페이지 링크 복사',
          icon: KitIconName.copy,
          run: (_) => run(() async {
            if (session.note.documentKind == VaultDocumentKind.office) {
              final repository = c.repository;
              final office = _office.currentState;
              final link = await office?.saveCurrentPageLink();
              if (!mounted ||
                  !identical(controller, c) ||
                  !identical(c.repository, repository) ||
                  !identical(c.activeSession, session) ||
                  !identical(_office.currentState, office)) {
                return;
              }
              if (link == null) {
                throw StateError('Office의 PDF 필기 페이지를 연 뒤 링크를 복사하세요.');
              }
              await Clipboard.setData(ClipboardData(text: link.toString()));
              return;
            }
            final editor = _editor.currentState;
            final page = editor?.coreInfo.pages
                .elementAtOrNull(editor.currentPageIndex)
                ?.pageId;
            await Clipboard.setData(
              ClipboardData(text: NoteLink(session.note.id, page).toString()),
            );
          }),
        ),
    ]);
  }

  /// The open note's attachments (favourites, supplement Task 9), in the
  /// vault it lives in; none for a PDF shown beside another note.
  NoteSideBinding? _noteSide() {
    final c = controller;
    final session = c?.activeSession;
    if (c == null || session == null || c.pdfPeerPreview) return null;
    return (store: NoteSideStore(session.repository), noteId: session.note.id);
  }

  /// What ⋯ 「문서 정보」 shows of the open note that this screen knows: when
  /// the vault last changed it (null before the library has read it) and
  /// the Drive state in a word or two, as the preview's 「동기화됨」.
  DocInfo _docInfo() {
    final note = controller?.activeSession?.note;
    final (sync, synced) = switch (_driveConnection) {
      null => ('연결 안 됨', false),
      final drive when drive.error != null => ('확인 필요', false),
      final drive when drive.waitingForLease => ('대기 중', false),
      final drive when !drive.ready || drive.busy => ('준비 중', false),
      final drive when !drive.connected => ('연결 안 됨', false),
      final drive => switch (drive.status.phase) {
        SyncPhase.pending => ('올릴 것 있음', false),
        SyncPhase.syncing => ('동기화 중', false),
        SyncPhase.conflict ||
        SyncPhase.retryWaiting ||
        SyncPhase.authenticationRequired ||
        SyncPhase.error => ('확인 필요', false),
        SyncPhase.synced || SyncPhase.idle || SyncPhase.closed => (
          '동기화됨',
          true,
        ),
      },
    };
    return DocInfo(
      // the editor's own last change first, as ⋯ 「문서 정보」 reads it
      lastEdited: docLastEdited(
        editor: _editorChrome.editorLastEdited,
        vault: note == null ? null : _documentFacts[note.id]?.changed,
      ),
      syncLabel: sync,
      synced: synced,
      // the open note is read from the vault's folder on this device
      offlineLabel: '준비됨',
    );
  }

  /// The function row's shortcuts (the documents other than the ink
  /// editor): the open document's actions in [noteShortcutItems] order.
  /// The editor's are left out while it is not on screen (an Office PDF
  /// shows them), and the vault ZIP without the engine (the app registry
  /// keeps it, switched off, for the settings page; the row never showed
  /// it then).
  List<AppAction> _rowShortcuts(
    WorkspaceController c, {
    required bool editorShown,
  }) => [
    for (final item in noteShortcutItems)
      if ((editorShown || !editorShortcutIds.contains(item.id)) &&
          (item.id != AppActionIds.vaultExport || c.native != null))
        ?_editorChrome.actions.lookup(item.id),
  ];
}

/// Opens [items] as a menu over the control [context] belongs to, where a
/// menu button opens its menu.
void _showMenuOn(BuildContext context, List<PopupMenuEntry<void>> items) {
  final button = context.findRenderObject() as RenderBox?;
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (button == null || !button.attached || overlay == null) return;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    ),
    Offset.zero & overlay.size,
  );
  unawaited(showMenu<void>(context: context, position: position, items: items));
}

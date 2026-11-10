import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' show PdfDocument;
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/docx_body_text.dart';
import 'package:saber/data/office/docx_find_replace.dart';
import 'package:saber/data/office/docx_paragraph_insert.dart';
import 'package:saber/data/office/docx_photo_replacement.dart';
import 'package:saber/data/office/docx_table_insert.dart';
import 'package:saber/data/office/docx_table_structure.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_edit_recovery.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/office/pptx_annotation_carry.dart';
import 'package:saber/data/office/pptx_find_replace.dart';
import 'package:saber/data/office/pptx_photo_addition.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';
import 'package:saber/data/office/pptx_shape_delete.dart';
import 'package:saber/data/office/pptx_shape_geometry.dart';
import 'package:saber/data/office/pptx_shape_order.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/data/office/pptx_slide_clone.dart';
import 'package:saber/data/office/pptx_slide_delete.dart';
import 'package:saber/data/office/pptx_slide_identity.dart';
import 'package:saber/data/office/pptx_slide_insert.dart';
import 'package:saber/data/office/pptx_slide_layout.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';
import 'package:saber/data/office/pptx_text_box.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/docx_body_text_dialog.dart';
import 'package:saber/pages/office/docx_find_replace_dialog.dart';
import 'package:saber/pages/office/docx_paragraph_dialog.dart';
import 'package:saber/pages/office/docx_table_dialog.dart';
import 'package:saber/pages/office/docx_table_structure_dialog.dart';
import 'package:saber/pages/office/office_original_preview.dart';
import 'package:saber/pages/office/pptx_find_replace_dialog.dart';
import 'package:saber/pages/office/pptx_photo_dialog.dart';
import 'package:saber/pages/office/pptx_shape_delete_dialog.dart';
import 'package:saber/pages/office/pptx_shape_geometry_dialog.dart';
import 'package:saber/pages/office/pptx_shape_order_dialog.dart';
import 'package:saber/pages/office/pptx_shape_text_dialog.dart';
import 'package:saber/pages/office/pptx_slide_clone_dialog.dart';
import 'package:saber/pages/office/pptx_slide_reorder_dialog.dart';
import 'package:saber/pages/office/pptx_speaker_notes_dialog.dart';
import 'package:saber/pages/office/pptx_table_add_dialog.dart';
import 'package:saber/pages/office/pptx_table_cell_text_dialog.dart';
import 'package:saber/pages/office/pptx_table_merge_dialog.dart';
import 'package:saber/pages/office/pptx_table_structure_dialog.dart';
import 'package:saber/pages/office/pptx_text_box_dialog.dart';
import 'package:saber/pages/office/windows_office_editor.dart';
import 'package:saber/pages/workspace/pdf_text_search_dialog.dart';

Uint8List _replacePptxPhotoDraft(
  (Uint8List, PptxPhotoTarget, WindowsOfficeImageAsset) input,
) => replacePptxPhoto(input.$1, input.$2, input.$3);

Uint8List _rotatePptxPhotoDraft((Uint8List, PptxPhotoTarget) input) =>
    rotatePptxPhoto(input.$1, input.$2);

Uint8List _deletePptxPhotoDraft((Uint8List, PptxPhotoTarget) input) =>
    deletePptxPhoto(input.$1, input.$2);

enum _SourceEdit {
  insertPhoto('사진을 추가', null),
  replacePhoto('사진을 교체', OfficePhotoAction.replace),
  removePhoto('사진을 삭제', OfficePhotoAction.remove),
  rotatePhoto('사진을 회전', OfficePhotoAction.rotate),
  insertTable('표를 추가', null),
  insertParagraph('본문 문단을 추가', null),
  replaceBodyText('본문 글자를 수정', null),
  findReplace('찾은 본문 글자를 변경', null),
  replaceCellText('표 셀 글자를 수정', null),
  editTableStructure('표 행·열을 편집', null);

  new(this.completed, this.photoAction);

  final String completed;
  final OfficePhotoAction? photoAction;
}

enum _PptxSlideEdit {
  findReplace('슬라이드 글자를 변경', '글자를 변경한'),
  insert('빈 슬라이드를 추가', '추가한'),
  layout('슬라이드 레이아웃을 변경', '레이아웃을 변경한'),
  photoAdd('사진을 추가', '사진을 추가한'),
  textBox('텍스트 상자를 추가', '텍스트 상자를 추가한'),
  presetShape('도형을 추가', '도형을 추가한'),
  tableAdd('표를 추가', '표를 추가한'),
  tableCellText('표 셀 글자를 수정', '표 셀 글자를 수정한'),
  tableStructure('표 행·열을 편집', '표 행·열을 편집한'),
  tableMerge('표 셀 병합을 편집', '표 셀 병합을 편집한'),
  speakerNotes('발표자 노트를 편집', '발표자 노트를 편집한'),
  shapeText('도형 텍스트를 수정', '도형 텍스트를 수정한'),
  shapeTextFormat('도형 글자 서식을 적용', '도형 글자 서식을 적용한'),
  shapeParagraphAlignment('도형 문단 정렬을 변경', '문단 정렬을 변경한'),
  shapeGeometry('개체 위치와 크기를 수정', '개체 위치와 크기를 수정한'),
  shapeOrder('개체 겹침 순서를 변경', '개체 순서를 변경한'),
  shapeDelete('도형을 삭제', '도형을 삭제한'),
  duplicate('슬라이드를 복제', '복제한'),
  reorder('슬라이드 순서를 변경', '순서를 변경한'),
  display('슬라이드의 발표 표시를 변경', '표시 상태를 변경한'),
  background('슬라이드 배경을 변경', '배경을 변경한'),
  delete('슬라이드를 삭제', '삭제하고 남은');

  new(this.completed, this.slideCountLabel);

  final String completed;
  final String slideCountLabel;
}

class OfficePageLinkRequest {
  const new _(this.repository, this.noteId, this.target);

  final NoteRepository repository;
  final String noteId;
  final OfficePageTarget target;
}

typedef _OfficePageLinkData = ({
  OfficePageLinkSelection selection,
  EditorCoreInfo snapshot,
});

typedef _OriginalPdfPage = ({
  String sourceRevisionId,
  String pdfSha256,
  String? bindingId,
  int number,
});

typedef _OriginalPageReveal = ({
  OfficeAnnotationSession annotation,
  OfficePdfVariant preview,
  String? annotationRevisionId,
  Set<String> annotationHeadIds,
  String pageId,
  String? previousPageId,
});

typedef _OriginalPageConflict = ({
  OfficePdfVariant preview,
  _OriginalPdfPage page,
  List<RevisionRecord> heads,
});

class OfficeWorkspace extends StatefulWidget {
  final NoteRepository repository;
  final VaultNote note;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final Future<void> Function(VaultNote)? onConvertedCopy;
  final VoidCallback onBack;
  final OfficePageLinkRequest? pageLink;
  final ValueChanged<OfficePageLinkRequest>? onPageLinkHandled;
  final AndroidOfficeEngine? engine;
  final WindowsOfficeEngine? windowsEngine;
  final HwpStructuredOfficeEngine? hwpEngine;
  final OfficePreviewEngine? previewEngine;
  final DocxBodyTextEngine? docxBodyText;
  final DocxFindReplaceEngine? docxFindReplace;
  final DocxParagraphInsertEngine? docxParagraphInsert;
  final DocxPhotoReplacementEngine? docxPhotoReplacement;
  final DocxTableInsertEngine? docxTableInsert;
  final DocxTableStructureEngine? docxTableStructure;
  final PptxFindReplaceEngine? pptxFindReplace;
  final PptxSlideCloneEngine? pptxSlideClone;
  final PptxSlideDeleteEngine? pptxSlideDelete;
  final PptxSlideIdentityEngine? pptxSlideIdentity;
  final PptxSlideInsertEngine? pptxSlideInsert;
  final PptxSlideLayoutEngine? pptxSlideLayout;
  final PptxSlideReorderEngine? pptxSlideReorder;
  final PptxPhotoAdditionEngine? pptxPhotoAddition;
  final PptxTextBoxEngine? pptxTextBox;
  final PptxTableAddEngine? pptxTableAdd;
  final PptxTableCellTextEngine? pptxTableCellText;
  final PptxTableStructureEngine? pptxTableStructure;
  final PptxTableMergeEngine? pptxTableMerge;
  final PptxSpeakerNotesEngine? pptxSpeakerNotes;
  final PptxShapeTextEngine? pptxShapeText;
  final PptxShapeGeometryEngine? pptxShapeGeometry;
  final PptxShapeOrderEngine? pptxShapeOrder;
  final PptxShapeDeleteEngine? pptxShapeDelete;
  final bool showBackButton;
  const new({
    super.key,
    required this.repository,
    required this.note,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.onConvertedCopy,
    required this.onBack,
    this.pageLink,
    this.onPageLinkHandled,
    this.engine,
    this.windowsEngine,
    this.hwpEngine,
    this.previewEngine,
    this.docxBodyText,
    this.docxFindReplace,
    this.docxParagraphInsert,
    this.docxPhotoReplacement,
    this.docxTableInsert,
    this.docxTableStructure,
    this.pptxFindReplace,
    this.pptxSlideClone,
    this.pptxSlideDelete,
    this.pptxSlideIdentity,
    this.pptxSlideInsert,
    this.pptxSlideLayout,
    this.pptxSlideReorder,
    this.pptxPhotoAddition,
    this.pptxTextBox,
    this.pptxTableAdd,
    this.pptxTableCellText,
    this.pptxTableStructure,
    this.pptxTableMerge,
    this.pptxSpeakerNotes,
    this.pptxShapeText,
    this.pptxShapeGeometry,
    this.pptxShapeOrder,
    this.pptxShapeDelete,
    this.showBackButton = true,
  });

  static Future<OfficePageLinkRequest> preparePageLink({
    required NoteRepository repository,
    required String noteId,
    required OfficePageTarget target,
  }) async {
    final request = OfficePageLinkRequest._(repository, noteId, target);
    final data = await _readPageLink(request);
    data.snapshot.dispose();
    return request;
  }

  static Future<_OfficePageLinkData> _readPageLink(
    OfficePageLinkRequest request,
  ) async {
    final selection = await resolveOfficePageLink(
      repository: request.repository,
      noteId: request.noteId,
      target: request.target,
    );
    final snapshot = await selection.annotation.load();
    try {
      if (selection.annotation.revision == null) {
        final document = await PdfDocument.openData(selection.bytes);
        try {
          _verifyBaselinePageLink(request, document.pages.length);
        } finally {
          await document.dispose();
        }
      } else if (snapshot.pages
              .where((page) => page.pageId == request.target.pageId)
              .singleOrNull ==
          null) {
        throw const FormatException('페이지 링크의 필기 페이지를 찾을 수 없습니다.');
      }
      await verifyOfficePageLinkSelection(selection);
      return (selection: selection, snapshot: snapshot);
    } catch (_) {
      snapshot.dispose();
      rethrow;
    }
  }

  static void _verifyBaselinePageLink(
    OfficePageLinkRequest request,
    int pageCount,
  ) {
    final target = request.target;
    if (pageCount > 0) {
      for (var index = -1; index < pageCount; index++) {
        if (officePdfBaselinePageId(target.pdfBindingId, index) ==
            target.pageId) {
          return;
        }
      }
    }
    throw const FormatException('페이지 링크의 PDF 페이지를 찾을 수 없습니다.');
  }

  @override
  State<OfficeWorkspace> createState() => OfficeWorkspaceState();
}

class OfficeWorkspaceState extends State<OfficeWorkspace> {
  static const _unavailable = AndroidOfficeCapabilities(
    available: false,
    engineVersion: '',
    editableFormats: [],
  );
  late OfficeDocumentStore _documents;
  late OfficeAnnotationStore _annotations;
  late OfficeViewStore _views;
  late OfficeEditRecoveryStore _recovery;
  List<OfficeEditRecoveryEntry> _recoveries = [];
  _OriginalPreviewData? _originalPreview;
  late Future<void> _initialLoad;
  StreamSubscription<void>? _changes;
  Timer? _refreshTimer;
  var _refreshAfterCommit = false;
  var _refreshAfterNativeEdit = false;
  OfficeEdition? _edition;
  List<OfficeEditionSummary> _editions = [];
  Set<String> _sourceHeads = {};
  List<OfficePdfVariant> _pdfVariants = const [];
  OfficePdfVariant? _selectedPdf;
  Uint8List? _selectedPdfBytes;
  List<RevisionRecord> _annotationHeads = [];
  OfficeAnnotationSession? _annotation;
  EditorCoreInfo? _incomingAnnotationSnapshot;
  var _annotationCheck = 0;
  var _incomingAnnotationAvailable = false;
  AndroidOfficeCapabilities _capabilities = _unavailable;
  var _editorKey = GlobalKey<EditorState>();
  String? _pdfPath;
  Future<void>? _nativeOperation;
  Future<void>? _commitOperation;
  int? _commitGeneration;
  Future<void>? _transitionOperation;
  Future<void>? _previewOperation;
  Future<void>? _recoveryOperation;
  Future<void>? _originalPreviewOperation;
  _PendingNative? _pendingNative;
  late WindowsOfficeEngine _windowsEngine;
  late HwpStructuredOfficeEngine _hwpEngine;
  Future<void>? _windowsPreparation;
  Future<void>? _windowsCommit;
  Future<WindowsOfficeDraftPreview>? _windowsPreview;
  Future<void>? _windowsRouteDone;
  Route<void>? _windowsRoute;
  _WindowsEditingSession? _windowsSession;
  _WindowsInteractiveEditing? _interactiveEditing;
  var _interactiveAvailable = false;
  var _windowsRendererAvailable = false;
  GlobalKey<WindowsOfficeEditorState>? _windowsEditorKey;
  var _loading = true;
  var _switching = false;
  var _pdfMode = false;
  var _editorDirty = false;
  var _editorBusy = false;
  var _annotationLoadFailed = false;
  var _nativeDirty = false;
  var _reportedDirty = false;
  var _reportedBusy = false;
  var _generation = 0;
  String? _error;
  String? _notice;
  String? _recoveryPath;
  String? _viewPageId;
  var _restoringView = false;
  OfficePageLinkRequest? _handledPageLink;
  var _pageLinkScheduled = false;
  ({OfficePageLinkRequest request, OfficeAnnotationSession annotation})?
  _pageLinkReveal;
  _OriginalPdfPage? _originalPreviewPage;
  _OriginalPageReveal? _originalPageReveal;
  _OriginalPageConflict? _originalPageConflict;

  bool get _dirty => _editorDirty || _nativeDirty;
  bool get _busy =>
      _loading ||
      _switching ||
      _nativeOperation != null ||
      _commitOperation != null ||
      _previewOperation != null ||
      _recoveryOperation != null ||
      _originalPreviewOperation != null ||
      _windowsPreparation != null ||
      _windowsCommit != null ||
      _windowsPreview != null ||
      _pageLinkReveal != null ||
      _originalPageReveal != null ||
      _editorBusy;
  AndroidOfficeEngine get _engine =>
      widget.engine ?? const AndroidOfficeEngine();
  bool get _useWindows =>
      widget.engine == null &&
      (_useHwp || widget.windowsEngine != null || Platform.isWindows);
  bool _isHwp(OfficeEdition? edition) =>
      edition != null &&
      const {
        '.hwp',
        '.hwpx',
      }.contains(p.extension(edition.originalFileName).toLowerCase());
  bool get _useHwp => widget.engine == null && _isHwp(_edition);
  WindowsOfficeEngine get _structuredEngine =>
      _useHwp ? _hwpEngine : _windowsEngine;

  bool get _liveNote =>
      widget.note.documentKind == VaultDocumentKind.office &&
      !widget.note.trashed &&
      !widget.note.deletionConflict;

  Object _noteScope(VaultNote note) => (
    note.id,
    note.sourceEntityId,
    note.inkEntityId,
    note.markdownEntityId,
    note.documentKind,
    note.trashed,
    note.deletionConflict,
  );

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final generation = _generation;
    _refreshAfterCommit = false;
    _refreshAfterNativeEdit = false;
    _clearIncomingAnnotation();
    _windowsEngine = widget.windowsEngine ?? WindowsOfficeEngine();
    _hwpEngine = widget.hwpEngine ?? HwpStructuredOfficeEngine();
    _documents = OfficeDocumentStore(widget.repository);
    _annotations = OfficeAnnotationStore(widget.repository);
    _views = OfficeViewStore(widget.repository, widget.note.id);
    _recovery = OfficeEditRecoveryStore(widget.repository);
    _initialLoad = _load();
    _changes = widget.repository.changes.listen((_) {
      if (!_current(generation)) return;
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 250), () {
        if (!_current(generation)) return;
        if (_commitOperation != null && _commitGeneration == generation) {
          _refreshAfterCommit = true;
          return;
        }
        if (_nativeOperation != null) {
          _refreshAfterNativeEdit = true;
          return;
        }
        if (!_loading && _previewOperation == null)
          unawaited(_run(_refreshOfficeWorkspace));
      });
    });
  }

  @override
  void didUpdateWidget(covariant OfficeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        _noteScope(oldWidget.note) != _noteScope(widget.note)) {
      final session = _windowsSession;
      if (session != null) unawaited(session.close());
      final interactive = _interactiveEditing;
      if (interactive != null) unawaited(interactive.abandon());
      _interactiveEditing = null;
      _interactiveAvailable = false;
      _windowsRendererAvailable = false;
      _generation++;
      unawaited(_changes?.cancel());
      _refreshTimer?.cancel();
      _edition = null;
      _editions = [];
      _resetPdfSelection();
      _annotation = null;
      _pdfMode = false;
      _viewPageId = null;
      _handledPageLink = null;
      _pageLinkReveal = null;
      _originalPageReveal = null;
      _restoringView = false;
      _editorDirty = false;
      _editorBusy = false;
      _nativeDirty = false;
      _pendingNative = null;
      _recoveries = [];
      _originalPreview = null;
      _recoveryOperation = null;
      _error = null;
      _notice = null;
      _recoveryPath = null;
      _loading = true;
      _switching = false;
      _editorKey = GlobalKey();
      _bind();
    }
    if (!identical(oldWidget.pageLink, widget.pageLink)) {
      if (_pageLinkReveal != null) {
        _pageLinkReveal = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => _report());
      }
      _schedulePageLink();
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  void _report() {
    if (!mounted) return;
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != _busy) {
      _reportedBusy = _busy;
      widget.onBusyChanged?.call(_busy);
    }
    _schedulePageLink();
  }

  void _schedulePageLink() {
    final request = widget.pageLink;
    if (_busy ||
        _pageLinkScheduled ||
        request == null ||
        identical(request, _handledPageLink)) {
      return;
    }
    _pageLinkScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _pageLinkScheduled = false;
      if (!mounted) return;
      final current = widget.pageLink;
      if (!_busy && current != null && !identical(current, _handledPageLink)) {
        unawaited(_applyPageLink(current));
      }
    });
    binding.ensureVisualUpdate();
  }

  bool _currentPageLinkRequest(OfficePageLinkRequest request, int generation) =>
      _current(generation) && identical(widget.pageLink, request);

  Future<void> _applyPageLink(OfficePageLinkRequest request) async {
    final generation = _generation;
    bool current() => _currentPageLinkRequest(request, generation);
    final existing = _transitionOperation;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {
        // The operation's caller reports its own error.
      }
    }
    if (!current() || _busy || identical(request, _handledPageLink)) return;
    _handledPageLink = request;
    await _transition(() async {
      _OfficePageLinkData? data;
      var transferred = false;
      setState(() => _switching = true);
      _report();
      try {
        if (!identical(widget.repository, request.repository) ||
            request.noteId != widget.note.id ||
            !_liveNote) {
          throw const FormatException('현재 Office 문서에 속하지 않는 페이지 링크입니다.');
        }
        await _saveCurrentContents();
        if (!current()) return;
        data = await OfficeWorkspace._readPageLink(request);
        if (!current()) return;
        final destination = data.selection;
        final editor = _editorKey.currentState;
        final annotation = _annotation;
        if (_pdfMode &&
            editor != null &&
            annotation != null &&
            !_annotationLoadFailed &&
            annotation.bindingId == destination.annotation.bindingId &&
            annotation.editionRevisionId ==
                destination.annotation.editionRevisionId &&
            annotation.revision?.revisionId ==
                destination.annotation.revision?.revisionId &&
            _selectedPdf?.revision.revisionId ==
                destination.preview.revision.revisionId &&
            _selectedPdf?.pdfSha256 == destination.preview.pdfSha256) {
          await WidgetsBinding.instance.endOfFrame;
          if (!current()) return;
          await verifyOfficePageLinkSelection(destination);
          if (!current()) return;
          if (!identical(_editorKey.currentState, editor) ||
              !_revealPageLink(editor, request.target.pageId)) {
            throw const FormatException('연결된 필기 페이지를 표시할 수 없습니다.');
          }
          await _rememberView();
          if (current()) _finishPageLink(request);
          return;
        }

        final edition = destination.edition;
        final preview = destination.preview;
        final snapshot = data.snapshot;
        final pdf = await _materializePdf(
          request.noteId,
          preview,
          destination.bytes,
        );
        if (destination.annotation.revision == null) {
          final document = await snapshot.assetCache.pdfDocumentCache.load(
            pdf.path,
            pdfBytes: destination.bytes,
          );
          OfficeWorkspace._verifyBaselinePageLink(
            request,
            document.pages.length,
          );
        }
        if (!current()) return;
        final interactive = await _interactiveFor(edition);
        final (capabilities, windowsRendererAvailable) = await _capabilitiesFor(
          edition,
          interactiveAvailable: interactive,
        );
        if (!current()) return;
        await verifyOfficePageLinkSelection(destination);
        if (!current()) return;
        setState(() {
          _edition = edition;
          if (!_editions.any(
            (item) => item.revision.revisionId == edition.revision.revisionId,
          )) {
            _editions = [..._editions, edition.summary];
          }
          _pdfVariants = destination.variants;
          _selectedPdf = preview;
          _selectedPdfBytes = destination.bytes;
          _capabilities = capabilities;
          _interactiveAvailable = interactive;
          _windowsRendererAvailable = windowsRendererAvailable;
          _annotation = destination.annotation;
          _annotationHeads = [?destination.annotation.revision];
          _clearIncomingAnnotation();
          _incomingAnnotationSnapshot = snapshot;
          _pdfPath = pdf.path;
          _pdfMode = true;
          _viewPageId = request.target.pageId;
          _restoringView = false;
          _editorKey = GlobalKey();
          _editorDirty = false;
          _editorBusy = true;
          _annotationLoadFailed = false;
          _pageLinkReveal = (
            request: request,
            annotation: destination.annotation,
          );
          _error = null;
          _notice = null;
        });
        transferred = true;
      } catch (error) {
        if (current()) _finishPageLink(request, error: error);
      } finally {
        if (!transferred) data?.snapshot.dispose();
        if (_current(generation)) {
          setState(() => _switching = false);
          _report();
        }
      }
    });
  }

  bool _revealPageLink(EditorState editor, String pageId) {
    final page = editor.coreInfo.pages
        .where((page) => page.pageId == pageId)
        .singleOrNull;
    return page != null &&
        editor.revealPage(pageId, background: page.backgroundImage);
  }

  void _finishPageLink(OfficePageLinkRequest request, {Object? error}) {
    if (!mounted || !identical(widget.pageLink, request)) return;
    setState(() {
      if (identical(_pageLinkReveal?.request, request)) _pageLinkReveal = null;
      if (error != null) _notice = 'Office 페이지 링크를 열 수 없습니다. $error';
    });
    _report();
    widget.onPageLinkHandled?.call(request);
  }

  Future<void> _revealLoadedPageLink(
    OfficePageLinkRequest request,
    OfficeAnnotationSession annotation,
    EditorCoreInfo core,
    int generation,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!_currentPageLinkRequest(request, generation) ||
        !identical(_pageLinkReveal?.annotation, annotation) ||
        !identical(_annotation, annotation)) {
      return;
    }
    final editor = _editorKey.currentState;
    if (editor == null ||
        !identical(editor.coreInfo, core) ||
        !_revealPageLink(editor, request.target.pageId)) {
      _finishPageLink(
        request,
        error: const FormatException('연결된 필기 페이지를 표시할 수 없습니다.'),
      );
      return;
    }
    await _rememberView();
    if (_currentPageLinkRequest(request, generation)) _finishPageLink(request);
    if (_current(generation)) unawaited(_run(_refreshAnnotationView));
  }

  Future<bool> _originalAnnotationCurrent(
    OfficeAnnotationSession annotation,
    String? revisionId,
    Set<String> expectedHeads,
  ) async {
    final heads = await widget.repository.heads(annotation.bindingId);
    return annotation.revision?.revisionId == revisionId &&
        (revisionId == null
            ? expectedHeads.isEmpty
            : expectedHeads.contains(revisionId)) &&
        setEquals(heads.map((head) => head.revisionId).toSet(), expectedHeads);
  }

  void _abortOriginalPageReveal(_OriginalPageReveal reveal, String message) {
    if (_originalPageReveal != reveal) return;
    setState(() {
      _originalPageReveal = null;
      _viewPageId = reveal.previousPageId;
      _pdfMode = false;
      _annotation = null;
      _annotationHeads = [];
      _clearIncomingAnnotation();
      _editorKey = GlobalKey();
      _editorBusy = false;
      _editorDirty = false;
      _annotationLoadFailed = false;
      _notice = message;
    });
    _report();
  }

  Future<void> _revealLoadedOriginalPage(
    _OriginalPageReveal reveal,
    EditorCoreInfo core,
    int generation,
  ) async {
    bool current() =>
        _current(generation) &&
        _originalPageReveal == reveal &&
        identical(_selectedPdf, reveal.preview) &&
        identical(_annotation, reveal.annotation);
    await WidgetsBinding.instance.endOfFrame;
    if (!current()) return;
    try {
      final sameRevision = await _originalAnnotationCurrent(
        reveal.annotation,
        reveal.annotationRevisionId,
        reveal.annotationHeadIds,
      );
      if (!current()) return;
      final editor = _editorKey.currentState;
      if (!sameRevision ||
          editor == null ||
          !identical(editor.coreInfo, core) ||
          !_revealPageLink(editor, reveal.pageId)) {
        _abortOriginalPageReveal(reveal, '미리보기와 연결된 필기 페이지를 표시할 수 없습니다.');
        return;
      }
      await _rememberView();
      if (!current()) return;
      setState(() => _originalPageReveal = null);
      _report();
      unawaited(_run(_refreshAnnotationView));
    } catch (_) {
      if (current()) {
        _abortOriginalPageReveal(reveal, '미리보기와 연결된 필기 판본을 다시 확인할 수 없습니다.');
      }
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final documents = _documents;
    final repository = widget.repository;
    final note = widget.note;
    final views = _views;
    final recovery = _recovery;
    try {
      final editions = await documents.readEditionSummaries(note);
      final heads = await repository.heads(note.sourceEntityId!);
      if (!_current(generation)) return;
      final active = heads.length == 1 && !heads.single.deleted
          ? editions
                .where(
                  (edition) =>
                      edition.revision.revisionId == heads.single.revisionId,
                )
                .singleOrNull
          : null;
      OfficeViewState? view;
      String? notice;
      try {
        view = await views.load();
      } catch (_) {
        notice = '이전 보기 상태를 복원하지 못했습니다. 원본 문서는 보존되어 있습니다.';
      }
      var recoveries = <OfficeEditRecoveryEntry>[];
      try {
        recoveries = await recovery.list(note);
      } catch (_) {
        notice = '이전 편집 작업을 확인하지 못했습니다. 작업 파일과 원본은 보관되어 있습니다.';
      }
      OfficeEdition? selected;
      var variants = const <OfficePdfVariant>[];
      OfficePdfVariant? selectedPdf;
      Object? openingError;
      Future<void> readSelected(String id) async {
        final edition = await documents.readLatest(note, revisionId: id);
        final pdfs = await documents.readPdfVariants(note, edition);
        selected = edition;
        variants = pdfs;
      }

      if (active != null) {
        final activeId = active.revision.revisionId;
        final viewId = view?.sourceRevisionId;
        final rememberedId =
            editions.any((item) => item.revision.revisionId == viewId)
            ? viewId
            : null;
        final firstId = rememberedId ?? activeId;
        try {
          await readSelected(firstId);
        } catch (error) {
          if (firstId == activeId) openingError = error;
        }
        if (!_current(generation)) return;
        final binding = view?.bindingId;
        if (binding != null) {
          selectedPdf = variants
              .where((variant) => variant.bindingId == binding)
              .singleOrNull;
        }
        if (view != null &&
            (rememberedId == null ||
                selected == null ||
                (binding != null && selectedPdf == null))) {
          if (firstId != activeId) {
            selected = null;
            variants = const [];
            try {
              await readSelected(activeId);
            } catch (error) {
              openingError = error;
            }
          }
          selectedPdf = null;
          if (selected != null) {
            notice = '이전 보기 상태의 문서 버전을 찾지 못했습니다. 현재 원본을 엽니다.';
          }
          view = null;
        }
      }
      final interactive = await _interactiveFor(selected);
      final (capabilities, windowsRendererAvailable) = await _capabilitiesFor(
        selected,
        interactiveAvailable: interactive,
      );
      if (!_current(generation)) return;
      setState(() {
        _capabilities = capabilities;
        _interactiveAvailable = interactive;
        _windowsRendererAvailable = windowsRendererAvailable;
        _editions = editions;
        _sourceHeads = heads.map((record) => record.revisionId).toSet();
        _edition = selected;
        _pdfVariants = variants;
        _selectedPdf = selectedPdf;
        _recoveries = recoveries;
        _viewPageId = active == null ? null : view?.pageId;
        _notice = notice;
        _error = openingError == null ? null : '문서를 열 수 없습니다: $openingError';
      });
      if (active != null && view?.pdfMode == true && selected != null) {
        try {
          if (selectedPdf == null) {
            throw const FormatException('Missing remembered PDF');
          }
          if (_current(generation)) await _openPdfNow(restoring: true);
        } catch (_) {
          if (_current(generation)) {
            setState(() {
              _pdfMode = false;
              _restoringView = false;
              _annotation = null;
              _editorBusy = false;
              _notice = '이전 PDF 필기 화면을 복원하지 못했습니다. 원본에서 필기 버전을 선택하세요.';
            });
          }
        }
      }
    } catch (error) {
      if (_current(generation)) setState(() => _error = '문서를 열 수 없습니다: $error');
    } finally {
      if (_current(generation)) {
        setState(() => _loading = false);
        _report();
      }
    }
  }

  Future<(AndroidOfficeCapabilities, bool)> _capabilitiesFor(
    OfficeEdition? edition, {
    bool interactiveAvailable = false,
  }) async {
    try {
      if (widget.engine != null) return (await _engine.capabilities(), false);
      if (_isHwp(edition)) {
        return (
          AndroidOfficeCapabilities(
            available: await _hwpEngine.available,
            engineVersion: 'HWP',
            editableFormats: HwpStructuredOfficeEngine.editableFormats,
            supportsHwp: true,
            supportsHwpx: true,
          ),
          false,
        );
      }
      if (widget.windowsEngine != null || Platform.isWindows) {
        final rendererAvailable = await _windowsEngine.available.catchError(
          (Object _) => false,
        );
        return (
          AndroidOfficeCapabilities(
            available: interactiveAvailable || rendererAvailable,
            engineVersion: 'Windows Office',
            editableFormats: WindowsOfficeEngine.editableFormats,
          ),
          rendererAvailable,
        );
      }
      return (await _engine.capabilities(), false);
    } catch (_) {
      return (_unavailable, false);
    }
  }

  Future<bool> _interactiveFor(OfficeEdition? edition) async {
    if (widget.engine != null ||
        _isHwp(edition) ||
        !(widget.windowsEngine != null || Platform.isWindows)) {
      return false;
    }
    try {
      return await _windowsEngine.interactiveAvailable;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshEditions() async {
    final generation = _generation;
    final heads = await widget.repository.heads(widget.note.sourceEntityId!);
    final ids = heads.map((record) => record.revisionId).toSet();
    if (ids.length == _sourceHeads.length && ids.containsAll(_sourceHeads))
      return;
    final editions = await _documents.readEditionSummaries(widget.note);
    if (!_current(generation)) return;
    setState(() {
      _sourceHeads = ids;
      _editions = editions;
    });
  }

  void _resetPdfSelection() {
    _pdfVariants = const [];
    _selectedPdf = null;
    _selectedPdfBytes = null;
    _originalPreviewPage = null;
    _originalPageConflict = null;
  }

  void _selectPublishedEdition(OfficeEdition edition) {
    _edition = edition;
    _resetPdfSelection();
    _originalPreview = null;
    _viewPageId = null;
    _error = null;
    _notice = null;
  }

  Future<void> _refreshPdfVariants() async {
    final edition = _edition;
    if (edition == null) return;
    final generation = _generation;
    final variants = await _documents.readPdfVariants(widget.note, edition);
    if (!_current(generation) || !identical(_edition, edition)) return;
    if (!listEquals(
      variants.map((variant) => variant.revision.revisionId).toList(),
      _pdfVariants.map((variant) => variant.revision.revisionId).toList(),
    )) {
      setState(() => _pdfVariants = variants);
    }
  }

  Future<void> _refreshOfficeWorkspace() async {
    await _refreshEditions();
    await _refreshPdfVariants();
    await _refreshAnnotationView();
  }

  Future<void> _refreshAnnotationView() async {
    final edition = _edition;
    final preview = _selectedPdf;
    if (!mounted ||
        !_pdfMode ||
        edition == null ||
        preview == null ||
        _pageLinkReveal != null ||
        _originalPageReveal != null ||
        _switching)
      return;
    final binding = preview.bindingId;
    final generation = _generation;
    final check = ++_annotationCheck;
    final repository = widget.repository;
    final annotation = _annotation;
    bool current() =>
        _current(generation) &&
        _annotationCheck == check &&
        _pdfMode &&
        !_switching &&
        identical(_edition, edition) &&
        identical(_selectedPdf, preview) &&
        identical(_annotation, annotation);

    final heads = await repository.heads(binding);
    if (!current()) return;
    final currentRevisionId = annotation?.revision?.revisionId;
    final incoming =
        annotation != null &&
        heads.any((head) => head.revisionId != currentRevisionId);
    if (incoming != _incomingAnnotationAvailable ||
        !listEquals(_annotationHeads, heads)) {
      setState(() {
        _annotationHeads = heads;
        _incomingAnnotationAvailable = incoming;
      });
    }
    if (!incoming ||
        heads.length != 1 ||
        _busy ||
        _editorDirty ||
        _annotationLoadFailed ||
        _transitionOperation != null)
      return;

    final head = heads.single;
    final next = await _annotations.open(
      widget.note,
      edition,
      preview: preview,
      revisionId: head.revisionId,
    );
    if (!current()) return;
    final snapshot = await next.load();
    var transferred = false;
    try {
      final latest = await repository.heads(binding);
      if (!current() ||
          _busy ||
          _editorDirty ||
          _transitionOperation != null ||
          annotation.revision?.revisionId != currentRevisionId ||
          latest.singleOrNull?.revisionId != head.revisionId)
        return;
      _captureViewPage();
      if (snapshot.pages.isNotEmpty &&
          !snapshot.pages.any((page) => page.pageId == _viewPageId)) {
        final index = _editorKey.currentState?.currentPageIndex ?? 0;
        _viewPageId =
            snapshot.pages[index.clamp(0, snapshot.pages.length - 1)].pageId;
      }
      setState(() {
        _clearIncomingAnnotation();
        _incomingAnnotationSnapshot = snapshot;
        _annotation = next;
        _editorKey = GlobalKey();
        _editorBusy = true;
      });
      transferred = true;
      _report();
    } finally {
      if (!transferred) snapshot.dispose();
    }
  }

  void _clearIncomingAnnotation() {
    _incomingAnnotationAvailable = false;
    _incomingAnnotationSnapshot?.dispose();
    _incomingAnnotationSnapshot = null;
  }

  Future<void> _run(Future<void> Function() operation) async {
    final generation = _generation;
    try {
      await operation();
    } catch (error) {
      if (_current(generation)) setState(() => _error = '$error');
    }
  }

  Future<void> save() async {
    await _initialLoad;
    final originalPreviewing = _originalPreviewOperation;
    if (originalPreviewing != null) await originalPreviewing;
    final recovering = _recoveryOperation;
    if (recovering != null) await recovering;
    final transition = _transitionOperation;
    if (transition != null) await transition;
    final previewing = _previewOperation;
    if (previewing != null) await previewing;
    final preparing = _windowsPreparation;
    if (preparing != null) await preparing;
    final windowsPreview = _windowsPreview;
    if (windowsPreview != null) await windowsPreview;
    final windowsEditor = _windowsEditorKey?.currentState;
    if (windowsEditor != null) {
      await windowsEditor.save();
      final closed = _windowsRouteDone;
      if (closed != null) await closed;
    }
    await _saveCurrentContents();
    await _rememberView();
  }

  void _captureViewPage() {
    if (!_pdfMode || _editorBusy) return;
    final editor = _editorKey.currentState;
    if (editor == null) return;
    final index = editor.currentPageIndex;
    if (index >= 0 && index < editor.coreInfo.pages.length) {
      _viewPageId = editor.coreInfo.pages[index].pageId;
    }
  }

  Future<bool> _rememberView({String? successNotice}) async {
    final edition = _edition;
    if (!mounted || edition == null) return false;
    _captureViewPage();
    final generation = _generation;
    final views = _views;
    bool current() => _current(generation) && identical(_edition, edition);
    final view = OfficeViewState(
      vaultId: views.vaultId,
      noteId: views.noteId,
      sourceRevisionId: edition.revision.revisionId,
      bindingId: _selectedPdf?.bindingId ?? edition.bindingId,
      pdfMode: _pdfMode,
      pageId: _viewPageId,
    );
    try {
      await views.save(view);
    } catch (_) {
      if (current()) {
        setState(() => _notice = '문서는 보관됐지만 이전 보기 상태를 저장하지 못했습니다.');
      }
      return false;
    }
    if (!current()) return false;
    if (successNotice != null) setState(() => _notice = successNotice);
    return true;
  }

  Future<void> _saveCurrentContents() async {
    final editing = _nativeOperation;
    if (editing != null) await editing;
    if (_pendingNative != null) await _commitPending();
    await _saveAnnotations();
  }

  Future<void> _saveAnnotations() async {
    if (!_pdfMode || _annotation == null) return;
    if (_annotationLoadFailed && !_editorDirty) return;
    final editor = _editorKey.currentState;
    if (editor == null) {
      if (_editorDirty || _editorBusy)
        throw StateError('PDF 필기를 여는 중입니다. 잠시 후 다시 시도하세요.');
      return;
    }
    await editor.saveToFile();
    await _annotation!.flush();
    if (_editorBusy ||
        _editorDirty ||
        editor.savingState.value != SavingState.saved)
      throw StateError('PDF 필기를 아직 저장하지 못했습니다. 편집 화면에서 다시 시도하세요.');
  }

  Future<void> _back() async {
    await save();
    if (mounted) widget.onBack();
  }

  Future<void> _transition(Future<void> Function() operation) {
    final current = _transitionOperation;
    if (current != null) return current;
    late Future<void> tracked;
    tracked = operation().whenComplete(() {
      if (identical(_transitionOperation, tracked)) _transitionOperation = null;
    });
    _transitionOperation = tracked;
    return tracked;
  }

  Future<void> _selectEdition(String id) =>
      _transition(() => _selectEditionNow(id));

  Future<void> _selectEditionNow(String id) async {
    if (_switching || _nativeOperation != null) return;
    final generation = _generation;
    setState(() => _switching = true);
    _report();
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final edition = await _documents.readLatest(widget.note, revisionId: id);
      final variants = await _documents.readPdfVariants(widget.note, edition);
      final interactive = await _interactiveFor(edition);
      final (capabilities, windowsRendererAvailable) = await _capabilitiesFor(
        edition,
        interactiveAvailable: interactive,
      );
      if (!_current(generation)) return;
      await _saveCurrentContents();
      if (!_current(generation)) return;
      setState(() {
        _edition = edition;
        _resetPdfSelection();
        _pdfVariants = variants;
        _capabilities = capabilities;
        _interactiveAvailable = interactive;
        _windowsRendererAvailable = windowsRendererAvailable;
        _pdfMode = false;
        _viewPageId = null;
        _restoringView = false;
        _annotation = null;
        _annotationHeads = [];
        _clearIncomingAnnotation();
        _editorKey = GlobalKey();
        _editorDirty = false;
        _editorBusy = false;
        _annotationLoadFailed = false;
        _notice = null;
        _error = null;
      });
      await _rememberView();
    } finally {
      if (_current(generation)) {
        setState(() => _switching = false);
        _report();
      }
    }
  }

  bool get _canEdit {
    final edition = _edition;
    if (!_liveNote || edition == null || !_capabilities.available) return false;
    final extension = p
        .extension(edition.originalFileName)
        .substring(1)
        .toLowerCase();
    if (extension == 'hwp' && !_capabilities.supportsHwp) return false;
    if (extension == 'hwpx' && !_capabilities.supportsHwpx) return false;
    return _capabilities.editableFormats
        .map((format) => format.toLowerCase().replaceFirst('.', ''))
        .contains(extension);
  }

  bool get _canGeneratePdf => widget.previewEngine != null || _canEdit;

  bool get _canPreview =>
      _edition != null &&
      (_edition!.pdfBytes != null ||
          _pdfVariants.isNotEmpty ||
          _canGeneratePdf);

  OfficePdfVariant? _choosePdf(List<OfficePdfVariant> variants) {
    final binding = _selectedPdf?.bindingId;
    return variants
            .where((variant) => variant.bindingId == binding)
            .singleOrNull ??
        variants.singleOrNull;
  }

  bool _supportsAndroidSourceActions(String extension) =>
      !_useWindows &&
      (widget.engine != null || Platform.isAndroid) &&
      p.extension(_edition?.originalFileName ?? '').toLowerCase() == extension;

  bool _canEditCurrentAndroidSource(String extension) =>
      _supportsAndroidSourceActions(extension) && _canEditCurrentSource;

  bool get _canEditCurrentSource =>
      _canEdit &&
      _sourceHeads.length == 1 &&
      _sourceHeads.contains(_edition?.revision.revisionId);

  bool get _supportsDocxSourceEdit =>
      _supportsAndroidSourceActions('.docx') ||
      (_useWindows &&
          _windowsRendererAvailable &&
          p.extension(_edition?.originalFileName ?? '').toLowerCase() ==
              '.docx');

  bool get _canEditCurrentAndroidPptx => _canEditCurrentAndroidSource('.pptx');

  bool get _canEditCurrentWindowsPptx =>
      _useWindows &&
      _windowsRendererAvailable &&
      p.extension(_edition?.originalFileName ?? '').toLowerCase() == '.pptx' &&
      _canEditCurrentSource;

  String? get _legacyCopyExtension =>
      switch (p.extension(_edition?.originalFileName ?? '').toLowerCase()) {
        '.doc' => 'docx',
        '.ppt' => 'pptx',
        _ => null,
      };

  bool get _canMakeLegacyCopy =>
      _legacyCopyExtension != null &&
      _canEditCurrentSource &&
      (_useWindows
          ? _windowsRendererAvailable
          : (widget.engine != null || Platform.isAndroid) &&
                _capabilities.supportsLegacyConversion);

  _OriginalPreviewData? get _selectedOriginalPreview {
    final preview = _originalPreview;
    final edition = _edition;
    if (preview == null ||
        edition == null ||
        preview.sourceRevisionId != edition.revision.revisionId ||
        preview.sourceSha256 != edition.originalSha256)
      return null;
    return preview;
  }

  ({Uint8List bytes, String sha256, String? bindingId})? _shownOriginalPdf(
    OfficeEdition edition,
  ) {
    final selected = _selectedPdf;
    final bytes = _selectedPdfBytes;
    if (bytes != null &&
        selected != null &&
        selected.sourceRevisionId == edition.revision.revisionId) {
      return (
        bytes: bytes,
        sha256: selected.pdfSha256,
        bindingId: selected.bindingId,
      );
    }
    final paired = edition.pdfBytes;
    final pairedHash = edition.pdfSha256;
    if (paired != null && pairedHash != null) {
      return (bytes: paired, sha256: pairedHash, bindingId: edition.bindingId);
    }
    final preview = _selectedOriginalPreview;
    return preview == null
        ? null
        : (bytes: preview.pdfBytes, sha256: preview.pdfSha256, bindingId: null);
  }

  bool _matchesShownOriginalPage(_OriginalPdfPage page) {
    final edition = _edition;
    if (_pdfMode || edition?.revision.revisionId != page.sourceRevisionId) {
      return false;
    }
    final shown = _shownOriginalPdf(edition!);
    return shown?.sha256 == page.pdfSha256 &&
        (page.bindingId == null || shown?.bindingId == page.bindingId);
  }

  bool _matchesOriginalVariant(
    _OriginalPdfPage page,
    OfficePdfVariant variant,
  ) =>
      variant.sourceRevisionId == page.sourceRevisionId &&
      variant.pdfSha256 == page.pdfSha256 &&
      (page.bindingId == null || variant.bindingId == page.bindingId);

  Future<void> _startOriginalPreview() {
    final pending = _originalPreviewOperation;
    if (pending != null) return pending;
    if (_busy ||
        !_canPreview ||
        _edition?.pdfBytes != null ||
        _selectedPdfBytes != null ||
        _selectedOriginalPreview != null)
      return Future.value();
    late Future<void> tracked;
    tracked = _loadOriginalPreview().whenComplete(() {
      if (identical(_originalPreviewOperation, tracked)) {
        _originalPreviewOperation = null;
        if (mounted) {
          _report();
          setState(() {});
        }
      }
    });
    _originalPreviewOperation = tracked;
    _report();
    if (mounted) setState(() {});
    return tracked;
  }

  Future<void> _loadOriginalPreview() async {
    final selected = _edition;
    if (selected == null) return;
    final generation = _generation;
    final documents = _documents;
    final note = widget.note;
    bool current() => _current(generation) && identical(_edition, selected);
    final saved = _choosePdf(_pdfVariants);
    if (saved != null) {
      final bytes = await documents.readPdfVariantBytes(note, selected, saved);
      if (!current()) return;
      setState(() {
        if (_selectedPdf?.bindingId != saved.bindingId) _viewPageId = null;
        _selectedPdf = saved;
        _selectedPdfBytes = bytes;
        _notice = null;
        _error = null;
      });
      return;
    }
    if (_pdfVariants.isNotEmpty) {
      setState(() => _notice = '미리 볼 PDF 버전을 선택하세요.');
      return;
    }
    if (!_canGeneratePdf) return;
    final engine =
        widget.previewEngine ??
        OfficePreviewEngine(
          windowsEngine: _windowsEngine,
          hwpEngine: _hwpEngine,
          androidEngine: _engine,
          isWindows: _useWindows,
          isAndroid: widget.engine != null || Platform.isAndroid,
        );
    final baseRoot = FileManager.getFile('/.working/office').absolute.path;
    final captured = await documents.beginEdit(
      note,
      revisionId: selected.revision.revisionId,
    );
    if (!current()) return;
    final sessionId = newId();
    final working = File(
      p.join(
        baseRoot,
        note.id,
        selected.revision.revisionId,
        sessionId,
        'original${p.extension(captured.originalFileName)}',
      ),
    );
    OfficePreviewResult? previewResult;
    try {
      await working.parent.create(recursive: true);
      await working.writeAsBytes(captured.originalBytes, flush: true);
      if (!current()) return;
      setState(() {
        _error = null;
        _notice = '원본을 바꾸지 않고 미리보기를 준비하고 있습니다.';
      });
      previewResult = await engine.preview(
        sourcePath: working.path,
        sessionId: sessionId,
      );
      final result = previewResult;
      if (!current()) return;
      if (result == null) {
        setState(() => _notice = null);
        return;
      }
      final sourceHash = sha256.convert(captured.originalBytes).toString();
      final bytes = await _readVerifiedOfficePreview(
        working,
        sourceHash,
        result,
      );
      if (!current()) return;
      setState(() {
        _originalPreview = _OriginalPreviewData(
          selected.revision.revisionId,
          sourceHash,
          bytes,
          result.pdfSha256,
          result.pageCount,
        );
        _notice = '원본 미리보기입니다. PDF 필기를 시작하면 필기 버전을 만듭니다.';
      });
    } finally {
      try {
        await previewResult?.dispose();
      } finally {
        if (p.isWithin(baseRoot, working.absolute.path) &&
            p.basename(working.parent.path) == sessionId &&
            FileSystemEntity.typeSync(working.path, followLinks: false) ==
                FileSystemEntityType.file) {
          try {
            await working.delete();
          } on FileSystemException {
            // Retain only this private input when an OS reader still owns it.
          }
        }
      }
    }
  }

  Future<Uint8List> _readVerifiedOfficePreview(
    File working,
    String sourceHash,
    OfficePreviewResult result,
  ) async {
    final pdf = File(result.pdfPath);
    if (result.sourceSha256 != sourceHash ||
        FileSystemEntity.typeSync(working.path, followLinks: false) !=
            FileSystemEntityType.file ||
        (await sha256.bind(working.openRead()).first).toString() !=
            sourceHash ||
        !p.isAbsolute(pdf.path) ||
        p.equals(pdf.path, working.path) ||
        FileSystemEntity.typeSync(pdf.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await pdf.length() > 128 * 1024 * 1024 ||
        result.pageCount < 1 ||
        result.engineVersion.trim().isEmpty) {
      throw const FormatException('원본에 연결된 미리보기를 확인하지 못했습니다.');
    }
    final bytes = await pdf.readAsBytes();
    if (sha256.convert(bytes).toString() != result.pdfSha256) {
      throw const FormatException('미리보기 PDF가 준비된 결과와 다릅니다.');
    }
    return bytes;
  }

  Future<void> _startPdfPreview({_OriginalPdfPage? originalPage}) {
    final pending = _previewOperation;
    if (pending != null) return pending;
    if (!_canPreview) return Future.value();
    if (originalPage != null && !_matchesShownOriginalPage(originalPage)) {
      throw const FormatException('미리보기 PDF가 바뀌었습니다. 페이지를 다시 선택하세요.');
    }
    final remembered = _originalPreviewPage;
    final handoff =
        originalPage ??
        (remembered != null && _matchesShownOriginalPage(remembered)
            ? remembered
            : null);
    final generation = _generation;
    late Future<void> tracked;
    tracked = _createPdfPreview(handoff).whenComplete(() {
      if (identical(_previewOperation, tracked)) _previewOperation = null;
      if (mounted) {
        _report();
        setState(() {});
        if (_current(generation)) unawaited(_run(_refreshOfficeWorkspace));
      }
    });
    _previewOperation = tracked;
    _report();
    if (mounted) {
      setState(() {
        _error = null;
        _notice = null;
      });
    }
    return tracked;
  }

  Future<void> _createPdfPreview(_OriginalPdfPage? originalPage) async {
    final selected = _edition;
    if (selected == null) return;
    final generation = _generation;
    final documents = _documents;
    final note = widget.note;
    bool current() => _current(generation) && identical(_edition, selected);

    final variants = await documents.readPdfVariants(note, selected);
    if (!current()) return;
    final existing = originalPage == null
        ? _choosePdf(variants)
        : variants
              .where(
                (variant) => _matchesOriginalVariant(originalPage, variant),
              )
              .singleOrNull;
    setState(() => _pdfVariants = variants);
    if (existing != null) {
      await _openPdfNow(preview: existing, originalPage: originalPage);
      return;
    }
    final cached = _selectedOriginalPreview;
    if (originalPage != null) {
      if (!_matchesShownOriginalPage(originalPage) ||
          originalPage.bindingId != null ||
          cached?.pdfSha256 != originalPage.pdfSha256) {
        throw const FormatException('미리보기와 같은 PDF 필기 버전을 찾을 수 없습니다.');
      }
    } else if (variants.isNotEmpty) {
      setState(() => _notice = '열 PDF 버전을 선택하세요.');
      return;
    }
    if (originalPage == null && !_canGeneratePdf) return;

    await _saveCurrentContents();
    if (!current()) return;
    final captured = await documents.beginEdit(
      note,
      revisionId: selected.revision.revisionId,
    );
    if (!current()) return;

    Future<void> publish(Uint8List bytes, int pageCount) async {
      final preview = await documents.commitDerivedPdf(
        captured,
        pdfBytes: bytes,
        pageCount: pageCount,
      );
      if (!current()) return;
      setState(() {
        _error = null;
        _recoveryPath = null;
      });
      await _refreshPdfVariants();
      if (current())
        await _openPdfNow(preview: preview, originalPage: originalPage);
    }

    if (cached != null) {
      await publish(cached.pdfBytes, cached.pageCount);
      return;
    }
    final engine =
        widget.previewEngine ??
        OfficePreviewEngine(
          windowsEngine: _windowsEngine,
          hwpEngine: _hwpEngine,
          androidEngine: _engine,
          isWindows: _useWindows,
          isAndroid: widget.engine != null || Platform.isAndroid,
        );
    final sessionId = newId();
    final working = FileManager.getFile(
      '/.working/office/${note.id}/${selected.revision.revisionId}/$sessionId/original${p.extension(captured.originalFileName)}',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(captured.originalBytes, flush: true);
    if (!current()) return;
    setState(() => _recoveryPath = working.parent.path);
    final result = await engine.preview(
      sourcePath: working.path,
      sessionId: sessionId,
    );
    try {
      if (!current() || result == null) return;
      final pdfBytes = await _readVerifiedOfficePreview(
        working,
        selected.originalSha256,
        result,
      );
      if (current()) await publish(pdfBytes, result.pageCount);
    } finally {
      await result?.dispose();
    }
  }

  Future<void> _launchEdit() async {
    if (_useWindows && (!_interactiveAvailable || _useHwp)) {
      return _launchWindowsEdit();
    }
    if (_nativeOperation != null || !_canEdit) return;
    await _trackNativeEdit(
      _useWindows ? _editInteractiveOriginal() : _editOriginal(),
    );
  }

  Future<void> _trackNativeEdit(Future<void> operation) async {
    _nativeOperation = operation;
    _report();
    if (mounted) setState(() {});
    try {
      await operation;
    } finally {
      if (identical(_nativeOperation, operation)) {
        _nativeOperation = null;
        final refresh = _refreshAfterNativeEdit;
        _refreshAfterNativeEdit = false;
        if (mounted) {
          _report();
          setState(() {});
          if (refresh && !_loading && _liveNote)
            await _run(_refreshOfficeWorkspace);
        }
      }
    }
  }

  Future<void> _makeLegacyCopy() async {
    final extension = _legacyCopyExtension;
    if (extension == null ||
        !_canMakeLegacyCopy ||
        _busy ||
        _pendingNative != null)
      return;
    final generation = _generation;
    final selected = _edition!;
    final note = widget.note;
    final documents = _documents;
    final useWindows = _useWindows;
    final windowsEngine = _windowsEngine;
    final androidEngine = _engine;
    bool current() =>
        _current(generation) &&
        widget.note.revision.revisionId == note.revision.revisionId &&
        _edition?.revision.revisionId == selected.revision.revisionId;
    void requireCurrent() {
      if (!current()) throw StateError('복사할 원본 판본이 바뀌었습니다.');
    }

    VaultNote? copy;
    await _trackNativeEdit(() async {
      final session = await documents.beginEdit(
        note,
        revisionId: selected.revision.revisionId,
      );
      requireCurrent();
      final cache = !useWindows && Platform.isAndroid
          ? await getTemporaryDirectory()
          : Directory.systemTemp;
      final work = await cache.createTemp('piv-office-legacy-copy-');
      try {
        final source = await File(
          p.join(
            work.path,
            'source${p.extension(session.originalFileName).toLowerCase()}',
          ),
        ).writeAsBytes(session.originalBytes, flush: true);
        requireCurrent();
        final sessionId = newId();
        final result = useWindows
            ? await windowsEngine.convertLegacy(
                source.path,
                sessionId: sessionId,
                expectedSourceSha256: selected.originalSha256,
              )
            : await androidEngine.convertLegacy(
                source: source,
                sessionId: sessionId,
                expectedSourceSha256: selected.originalSha256,
              );
        requireCurrent();
        if (result == null) return;
        if (result.targetExtension != extension) {
          throw const FormatException('편집용 복사본의 형식을 확인하지 못했습니다.');
        }
        copy = await documents.createConvertedCopy(
          session,
          originalBytes: result.originalBytes,
          pdfBytes: result.pdfBytes,
          engineVersion: result.engineVersion,
          pageCount: result.pageCount,
          beforePublish: requireCurrent,
        );
      } finally {
        try {
          if (FileSystemEntity.typeSync(work.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            await work.delete(recursive: true);
          }
        } on FileSystemException {
          // The original and published copy do not depend on this draft.
        }
      }
    }());
    final created = copy;
    if (created == null || !current()) return;
    setState(() {
      _error = null;
      _notice = '편집용 복사본을 저장했습니다. ${created.title}';
    });
    await widget.onConvertedCopy?.call(created);
  }

  Future<void> _launchSourceEdit(String extension, _SourceEdit edit) async {
    final allowed = switch (edit) {
      _SourceEdit.editTableStructure || _SourceEdit.findReplace =>
        extension == '.docx' &&
            _supportsDocxSourceEdit &&
            _canEditCurrentSource,
      _ => _canEditCurrentAndroidSource(extension),
    };
    if (_busy || _pendingNative != null || !allowed) return;
    await _trackNativeEdit(_editSource(extension, edit));
  }

  Future<void> _editSource(String extension, _SourceEdit edit) async {
    final action = edit.photoAction;
    final draftName = switch (edit) {
      _SourceEdit.insertTable => 'table',
      _SourceEdit.insertParagraph => 'paragraph',
      _SourceEdit.replaceBodyText => 'body-text',
      _SourceEdit.findReplace => 'find-replace',
      _SourceEdit.replaceCellText => 'table-cell-text',
      _SourceEdit.editTableStructure => 'table-structure',
      _ => 'photo',
    };
    final selected = _edition!;
    final note = widget.note;
    final documents = _documents;
    final generation = _generation;
    final sourceRevisionId = selected.revision.revisionId;
    bool current() =>
        _current(generation) &&
        widget.note.revision.revisionId == note.revision.revisionId &&
        _edition?.revision.revisionId == sourceRevisionId;
    void requireCurrent() {
      if (!current()) throw StateError('보는 문서 또는 원본 판본이 바뀌었습니다.');
    }

    final captured = await documents.beginEdit(
      note,
      revisionId: sourceRevisionId,
    );
    if (!current()) return;
    Future<void> requireLatestSource() async {
      final heads = await documents.repository.heads(captured.sourceEntityId);
      requireCurrent();
      if (heads.length != 1 || heads.single.revisionId != sourceRevisionId) {
        final target = switch (edit) {
          _SourceEdit.insertTable => '표 위치를',
          _SourceEdit.insertParagraph => '문단 위치를',
          _SourceEdit.insertPhoto => '사진 위치를',
          _SourceEdit.replaceBodyText => '수정할 글자를',
          _SourceEdit.findReplace => '바꿀 글자를',
          _SourceEdit.replaceCellText => '수정할 셀을',
          _SourceEdit.editTableStructure => '편집할 표를',
          _ => '사진을',
        };
        throw StateError('새 원본 판본을 받았습니다. 최신 판본에서 $target 다시 선택하세요.');
      }
    }

    final windows = _useWindows;
    final engine =
        widget.previewEngine ??
        OfficePreviewEngine(
          windowsEngine: _windowsEngine,
          androidEngine: _engine,
          isWindows: windows,
          isAndroid: !windows,
        );
    final sessionId = newId();
    final parent = Directory(
      p.join(
        FileManager.getRootDirectory().absolute.path,
        '.working',
        'office',
        note.id,
        sourceRevisionId,
      ),
    );
    await parent.create(recursive: true);
    final work = await parent.createTemp('$draftName-');
    final source = File(p.normalize(p.join(work.path, 'source$extension')));
    final asset = File(p.normalize(p.join(work.path, 'replacement.image')));
    final working = File(
      p.normalize(p.join(work.path, '$draftName$extension')),
    );
    OfficePreviewResult? preview;
    try {
      requireCurrent();
      if (_error != null || _notice != null) {
        setState(() {
          _error = null;
          _notice = null;
        });
      }
      final Uint8List bytes;
      final String sourceHash;
      if (extension == '.docx') {
        final nativeDirectory = p.normalize(await work.resolveSymbolicLinks());
        String nativePath(File file) =>
            p.join(nativeDirectory, p.basename(file.path));
        await source.create(exclusive: true);
        await source.writeAsBytes(captured.originalBytes, flush: true);
        if (edit == _SourceEdit.findReplace) {
          if (!mounted || !current()) return;
          final editor =
              widget.docxFindReplace ?? const DocxFindReplaceEngine();
          final choice = await chooseDocxFindReplace(context, (find) async {
            await requireLatestSource();
            final plan = await editor.preview(
              sourcePath: nativePath(source),
              sourceSha256: selected.originalSha256,
              find: find,
            );
            requireCurrent();
            if (plan.sourceSha256 != selected.originalSha256) {
              throw const FormatException('찾을 DOCX 원본이 바뀌었습니다.');
            }
            return plan;
          });
          if (choice == null || !current()) return;
          await requireLatestSource();
          final output = await editor.replaceAll(
            sourcePath: nativePath(source),
            plan: choice.preview,
            outputPath: nativePath(working),
            replacement: choice.replacement,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.matchCount != choice.preview.matchCount ||
              output.paragraphCount != choice.preview.paragraphCount) {
            throw const FormatException('바꾼 글자의 수와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.replaceBodyText) {
          final editor = widget.docxBodyText ?? const DocxBodyTextEngine();
          final plan = await editor.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('편집할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxBodyText(context, plan);
          if (choice == null || !current()) return;
          await requireLatestSource();
          final output = await editor.replace(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            paragraphIndex: choice.paragraphIndex,
            runIndex: choice.runIndex,
            text: choice.text,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.paragraphIndex != choice.paragraphIndex ||
              output.runIndex != choice.runIndex) {
            throw const FormatException('수정한 글자의 위치와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.replaceCellText) {
          final editor = widget.docxBodyText ?? const DocxBodyTextEngine();
          final plan = await editor.inspectCells(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('편집할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxTableCellText(context, plan);
          if (choice == null || !current()) return;
          await requireLatestSource();
          final output = await editor.replaceCell(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            address: choice.address,
            paragraphIndex: choice.paragraphIndex,
            runIndex: choice.runIndex,
            text: choice.text,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.address != choice.address ||
              output.paragraphIndex != choice.paragraphIndex ||
              output.runIndex != choice.runIndex) {
            throw const FormatException('수정한 셀의 위치와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.editTableStructure) {
          final editor =
              widget.docxTableStructure ?? const DocxTableStructureEngine();
          final plan = await editor.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('편집할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxTableStructure(context, plan);
          if (choice == null || !current()) return;
          final table = plan.tables.singleWhere(
            (table) => table.tableIndex == choice.tableIndex,
          );
          await requireLatestSource();
          final output = await editor.edit(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            tableIndex: choice.tableIndex,
            action: choice.action,
            index: choice.index,
            anchorIndex: choice.anchorIndex,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.tableIndex != choice.tableIndex ||
              output.rowCount != table.rowCount + choice.action.rowDelta ||
              output.columnCount !=
                  table.columnCount + choice.action.columnDelta) {
            throw const FormatException('편집한 표의 행·열과 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.insertParagraph) {
          final inserter =
              widget.docxParagraphInsert ?? const DocxParagraphInsertEngine();
          final plan = await inserter.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('문단을 추가할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxParagraph(context, plan);
          if (choice == null || !current()) return;
          await requireLatestSource();
          final output = await inserter.insert(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            anchorParagraphIndex: choice.anchorParagraphIndex,
            position: choice.position,
            text: choice.text,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.paragraphIndex !=
                  choice.position.insertionIndex(choice.anchorParagraphIndex)) {
            throw const FormatException('추가한 문단의 위치와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.insertPhoto) {
          final inserter =
              widget.docxParagraphInsert ?? const DocxParagraphInsertEngine();
          final plan = await inserter.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('사진을 추가할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxPhotoInsertion(context, plan);
          if (choice == null || !current()) return;
          await asset.create(exclusive: true);
          await asset.writeAsBytes(choice.image.bytes, flush: true);
          await requireLatestSource();
          final output = await inserter.insertPhoto(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            anchorParagraphIndex: choice.anchorParagraphIndex,
            position: choice.position,
            assetPath: nativePath(asset),
            assetSha256: choice.image.sha256,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.paragraphIndex !=
                  choice.position.insertionIndex(choice.anchorParagraphIndex)) {
            throw const FormatException('추가한 사진의 위치와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else if (edit == _SourceEdit.insertTable) {
          final inserter =
              widget.docxTableInsert ?? const DocxTableInsertEngine();
          final plan = await inserter.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('표를 추가할 DOCX 원본이 바뀌었습니다.');
          }
          final choice = await chooseDocxTable(context, plan);
          if (choice == null || !current()) return;
          await requireLatestSource();
          final output = await inserter.insert(
            sourcePath: nativePath(source),
            plan: plan,
            outputPath: nativePath(working),
            afterParagraphIndex: choice.afterParagraphIndex,
            cells: choice.cells,
          );
          requireCurrent();
          if (output.sourceSha256 != selected.originalSha256 ||
              output.afterParagraphIndex != choice.afterParagraphIndex ||
              output.rows != choice.cells.length ||
              output.columns != choice.cells.first.length ||
              output.tableIndex < 0) {
            throw const FormatException('추가한 표의 위치와 DOCX 판본을 확인하지 못했습니다.');
          }
          sourceHash = output.outputSha256;
        } else {
          final photoAction = action!;
          final replacer =
              widget.docxPhotoReplacement ?? const DocxPhotoReplacementEngine();
          final plan = await replacer.inspect(
            sourcePath: nativePath(source),
            sourceSha256: selected.originalSha256,
          );
          if (!mounted || !current()) return;
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('편집할 DOCX 원본이 바뀌었습니다.');
          }
          if (photoAction != OfficePhotoAction.replace) {
            final target = await chooseDocxPhotoTarget(
              context,
              captured.originalBytes,
              plan,
              photoAction,
            );
            if (target == null || !current()) return;
            await requireLatestSource();
            final mutate = photoAction == OfficePhotoAction.rotate
                ? replacer.rotate
                : replacer.remove;
            sourceHash = await mutate(
              sourcePath: nativePath(source),
              plan: plan,
              photoIndex: target.index,
              outputPath: nativePath(working),
            );
          } else {
            final choice = await chooseDocxPhotoReplacement(
              context,
              captured.originalBytes,
              plan,
            );
            if (choice == null || !current()) return;
            await requireLatestSource();
            if (choice.target.mediaSha256 == choice.image.sha256) {
              setState(() => _notice = '원본과 같은 사진을 선택했습니다.');
              return;
            }
            await asset.create(exclusive: true);
            await asset.writeAsBytes(choice.image.bytes, flush: true);
            sourceHash = await replacer.replace(
              sourcePath: nativePath(source),
              plan: plan,
              photoIndex: choice.target.index,
              outputPath: nativePath(working),
              assetPath: nativePath(asset),
              assetSha256: choice.image.sha256,
            );
          }
        }
        final length = await working.length();
        if (length < 1 || length > 128 * 1024 * 1024) {
          throw const FormatException('편집한 DOCX의 크기를 확인하지 못했습니다.');
        }
        bytes = await working.readAsBytes();
        if (bytes.length != length ||
            sourceHash == selected.originalSha256 ||
            sha256.convert(bytes).toString() != sourceHash) {
          throw const FormatException('편집한 DOCX의 바이트가 바뀌었습니다.');
        }
      } else {
        if (!mounted || !current()) return;
        final photoAction = action!;
        if (photoAction != OfficePhotoAction.replace) {
          final target = await choosePptxPhotoTarget(
            context,
            captured.originalBytes,
            photoAction,
          );
          if (target == null || !current()) return;
          await requireLatestSource();
          final mutate = photoAction == OfficePhotoAction.rotate
              ? _rotatePptxPhotoDraft
              : _deletePptxPhotoDraft;
          bytes = await compute(mutate, (captured.originalBytes, target));
        } else {
          final choice = await choosePptxPhotoReplacement(
            context,
            captured.originalBytes,
          );
          if (choice == null || !current()) return;
          await requireLatestSource();
          bytes = await compute(_replacePptxPhotoDraft, (
            captured.originalBytes,
            choice.target,
            choice.image,
          ));
        }
        sourceHash = sha256.convert(bytes).toString();
        requireCurrent();
        await working.create(exclusive: true);
        await working.writeAsBytes(bytes, flush: true);
      }
      requireCurrent();
      preview = await engine.preview(
        sourcePath: working.path,
        sessionId: sessionId,
      );
      requireCurrent();
      if (preview == null) {
        if (edit == _SourceEdit.editTableStructure ||
            edit == _SourceEdit.findReplace ||
            edit == _SourceEdit.insertPhoto) {
          throw const FormatException('편집한 DOCX의 PDF를 만들지 못했습니다.');
        }
        return;
      }
      final pdf = await _readVerifiedOfficePreview(
        working,
        sourceHash,
        preview,
      );
      requireCurrent();
      final edition = await documents.commitEdited(
        captured,
        originalBytes: bytes,
        pdfBytes: pdf,
        engineVersion: preview.engineVersion,
        pageCount: preview.pageCount,
        requireCurrentHeads: true,
        beforePublish: requireCurrent,
      );
      if (!current()) return;
      setState(() {
        _selectPublishedEdition(edition);
        _editions = [edition.summary, ..._editions];
        _sourceHeads = {edition.revision.revisionId};
      });
      final viewSaved = await _rememberView(
        successNotice: '${edit.completed}하고 새 원본과 PDF를 저장했습니다.',
      );
      if (!_current(generation)) return;
      try {
        await _refreshEditions();
      } catch (_) {
        if (viewSaved && _current(generation)) {
          setState(() {
            _notice = switch (edit) {
              _SourceEdit.insertTable => '표를 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _SourceEdit.insertParagraph =>
                '본문 문단을 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _SourceEdit.replaceBodyText =>
                '본문 글자를 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _SourceEdit.findReplace =>
                '찾아 바꾼 글자를 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _SourceEdit.replaceCellText =>
                '표 셀 글자를 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _SourceEdit.editTableStructure =>
                '표 편집을 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
              _ => '사진을 저장했습니다. 판본 목록을 다시 열어 확인하세요.',
            };
          });
        }
      }
    } finally {
      try {
        await preview?.dispose();
      } finally {
        for (final file in [source, asset, working]) {
          try {
            if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
                FileSystemEntityType.file) {
              await file.delete();
            }
          } on FileSystemException {
            // A native reader can still own this private draft.
          }
        }
        try {
          if (FileSystemEntity.typeSync(work.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            await work.delete();
          }
        } on FileSystemException {
          // Preserve a working folder while the native reader closes.
        }
      }
    }
  }

  Future<void> _launchPptxSlideEdit(_PptxSlideEdit action) async {
    final windows = _useWindows;
    final allowed = windows
        ? (action == _PptxSlideEdit.findReplace ||
                  action == _PptxSlideEdit.tableStructure ||
                  action == _PptxSlideEdit.tableMerge ||
                  action == _PptxSlideEdit.speakerNotes ||
                  action == _PptxSlideEdit.shapeParagraphAlignment ||
                  action == _PptxSlideEdit.shapeOrder) &&
              _canEditCurrentWindowsPptx
        : _canEditCurrentAndroidPptx;
    if (_busy || _pendingNative != null || !allowed) return;
    await _trackNativeEdit(_editPptxSlide(action, windows: windows));
  }

  Future<void> _editPptxSlide(
    _PptxSlideEdit action, {
    required bool windows,
  }) async {
    final selected = _edition!;
    final note = widget.note;
    final documents = _documents;
    final clone = widget.pptxSlideClone ?? const PptxSlideCloneEngine();
    final mover = widget.pptxSlideReorder ?? const PptxSlideReorderEngine();
    final engine = _engine;
    final windowsPreview = windows
        ? OfficePreviewEngine(windowsEngine: _windowsEngine, isWindows: true)
        : null;
    final generation = _generation;
    final sourceRevisionId = selected.revision.revisionId;
    bool current() =>
        _current(generation) &&
        widget.note.revision.revisionId == note.revision.revisionId &&
        _edition?.revision.revisionId == sourceRevisionId;
    void requireCurrent() {
      if (!current()) throw StateError('편집할 PPTX 판본이 바뀌었습니다.');
    }

    final captured = await documents.beginEdit(
      note,
      revisionId: sourceRevisionId,
    );
    if (!current()) return;
    Future<void> requireLatestSource() async {
      final heads = await documents.repository.heads(captured.sourceEntityId);
      requireCurrent();
      if (heads.length != 1 || heads.single.revisionId != sourceRevisionId) {
        throw StateError('새 PPTX 판본을 받았습니다. 최신 판본에서 슬라이드를 다시 선택하세요.');
      }
    }

    await requireLatestSource();
    final parent = Directory(
      p.join(
        FileManager.getRootDirectory().absolute.path,
        '.working',
        'office',
        note.id,
        sourceRevisionId,
      ),
    );
    await parent.create(recursive: true);
    final work = await parent.createTemp('${action.name}-');
    final source = File(p.normalize(p.join(work.path, 'source.pptx')));
    final output = File(p.normalize(p.join(work.path, 'edited.pptx')));
    final asset = action == _PptxSlideEdit.photoAdd
        ? File(p.normalize(p.join(work.path, 'photo.image')))
        : null;
    AndroidOfficeNativeObservationResult? observation;
    OfficePreviewResult? rendered;
    try {
      requireCurrent();
      await source.create(exclusive: true);
      await source.writeAsBytes(captured.originalBytes, flush: true);
      final String outputSha256;
      final int slideCount;
      var completedAction = action.completed;
      if (action == _PptxSlideEdit.findReplace) {
        if (!mounted || !current()) return;
        final editor = widget.pptxFindReplace ?? const PptxFindReplaceEngine();
        final draft = await choosePptxFindReplace(context, (find) async {
          await requireLatestSource();
          final plan = await editor.preview(
            sourcePath: source.path,
            sourceSha256: selected.originalSha256,
            find: find,
          );
          requireCurrent();
          if (plan.sourceSha256 != selected.originalSha256) {
            throw const FormatException('찾을 PPTX 원본이 바뀌었습니다.');
          }
          return plan;
        });
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.replaceAll(
          sourcePath: source.path,
          plan: draft.preview,
          outputPath: output.path,
          replacement: draft.replacement,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != draft.preview.slideCount ||
            result.matchCount != draft.preview.matchCount) {
          throw const FormatException('바꾼 글자의 수와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.reorder) {
        final plan = await mover.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('순서를 변경할 PPTX 원본이 바뀌었습니다.');
        }
        if (plan.slideCount < 2) {
          throw const FormatException('순서를 변경하려면 슬라이드가 두 개 이상 필요합니다.');
        }
        final move = await choosePptxSlideMove(context, plan);
        if (move == null || !current()) return;
        final destination = PptxSlideReorderEngine.destinationIndex(
          move.sourceIndex,
          move.targetIndex,
          after: move.after,
        );
        await requireLatestSource();
        final result = await mover.move(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          sourceIndex: move.sourceIndex,
          targetIndex: move.targetIndex,
          after: move.after,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.sourceIndex != move.sourceIndex ||
            result.destinationIndex != destination) {
          throw const FormatException('순서를 변경한 PPTX의 판본과 위치를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
        if (destination == move.sourceIndex) {
          completedAction = '슬라이드 구역을 변경';
        }
      } else if (action == _PptxSlideEdit.display) {
        final plan = await mover.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('발표 표시를 변경할 PPTX 원본이 바뀌었습니다.');
        }
        final index = await choosePptxSlideDisplay(context, plan);
        if (index == null || !current()) return;
        final expectedHidden = plan.slides[index].hidden;
        await requireLatestSource();
        final result = await mover.setHidden(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: index,
          expectedHidden: expectedHidden,
          hidden: !expectedHidden,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != index ||
            result.hidden == expectedHidden) {
          throw const FormatException('발표 표시를 변경한 PPTX의 판본과 슬라이드를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.background) {
        final plan = await mover.inspectBackground(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('배경을 변경할 PPTX 원본이 바뀌었습니다.');
        }
        if (!plan.slides.any(
          (slide) =>
              slide.background != null && slide.background != 'unsupported',
        )) {
          throw const FormatException('이 PPTX에는 단색 배경을 변경할 수 있는 슬라이드가 없습니다.');
        }
        final change = await choosePptxSlideBackground(context, plan);
        if (change == null || !current()) return;
        await requireLatestSource();
        final result = await mover.setBackground(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: change.index,
          background: change.background,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != change.index ||
            result.background != change.background) {
          throw const FormatException('배경을 변경한 PPTX의 판본과 슬라이드를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.duplicate) {
        final plan = await clone.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('복제할 PPTX 원본이 바뀌었습니다.');
        }
        final index = await choosePptxSlideToClone(context, plan);
        if (index == null || !current()) return;
        await requireLatestSource();
        final result = await clone.duplicate(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: index,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount + 1 ||
            result.slideCount > 256 ||
            result.duplicateIndex != index + 1) {
          throw const FormatException('복제한 PPTX의 판본과 순서를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (asset != null) {
        final editor =
            widget.pptxPhotoAddition ?? const PptxPhotoAdditionEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('사진을 추가할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxPhotoAddition(context, plan);
        if (draft == null || !current()) return;
        await asset.create(exclusive: true);
        await asset.writeAsBytes(draft.image.bytes, flush: true);
        await requireLatestSource();
        final result = await editor.add(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          assetPath: asset.path,
          assetSha256: draft.image.sha256,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId < 1 ||
            result.shapeId > 0xffffffff) {
          throw const FormatException('사진을 추가한 슬라이드와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.textBox ||
          action == _PptxSlideEdit.presetShape) {
        final editor = widget.pptxTextBox ?? const PptxTextBoxEngine();
        final preset = action == _PptxSlideEdit.presetShape;
        final inspect = preset ? editor.inspectPresetShapes : editor.inspect;
        final target = preset ? '도형을' : '텍스트 상자를';
        final plan = await inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw FormatException('$target 추가할 PPTX 원본이 바뀌었습니다.');
        }
        if (!plan.slides.any((slide) => slide.canAdd)) {
          throw FormatException('$target 추가할 수 있는 슬라이드가 없습니다.');
        }
        final draft = await choosePptxTextBox(
          context,
          plan,
          addPresetShape: preset,
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final shape = draft.shape;
        final result = shape == null
            ? await editor.add(
                sourcePath: source.path,
                plan: plan,
                outputPath: output.path,
                slideIndex: draft.slideIndex,
                text: draft.text,
                placement: draft.placement,
                fontSize: draft.fontSize,
              )
            : await editor.addPresetShape(
                sourcePath: source.path,
                plan: plan,
                outputPath: output.path,
                slideIndex: draft.slideIndex,
                text: draft.text,
                placement: draft.placement,
                fontSize: draft.fontSize,
                preset: shape.kind,
                fillColor: shape.fillColor,
                lineColor: shape.lineColor,
              );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId < 1 ||
            result.shapeId > 0xffffffff) {
          throw FormatException('$target 추가한 슬라이드와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.tableAdd) {
        final editor = widget.pptxTableAdd ?? const PptxTableAddEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('표를 추가할 PPTX 원본이 바뀌었습니다.');
        }
        if (!plan.slides.any((slide) => slide.canAdd)) {
          throw const FormatException('표를 추가할 수 있는 슬라이드가 없습니다.');
        }
        final draft = await choosePptxTable(context, plan);
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.add(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          rows: draft.rows,
          columns: draft.columns,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId < 1 ||
            result.shapeId > 0xffffffff ||
            result.rows != draft.rows ||
            result.columns != draft.columns) {
          throw const FormatException('추가한 표의 크기와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.tableCellText) {
        final editor =
            widget.pptxTableCellText ?? const PptxTableCellTextEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('표 셀을 수정할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxTableCellText(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.replace(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          shapeId: draft.shapeId,
          row: draft.row,
          column: draft.column,
          changes: draft.changes,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.shapeId ||
            result.row != draft.row ||
            result.column != draft.column) {
          throw const FormatException('수정한 표 셀과 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.tableStructure) {
        final editor =
            widget.pptxTableStructure ?? const PptxTableStructureEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('표 행·열을 편집할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxTableStructure(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.edit(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          table: draft.table,
          action: draft.action,
          index: draft.index,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.table.shapeId ||
            result.action != draft.action ||
            result.index != draft.index ||
            result.rows != draft.table.rows + draft.action.rowDelta ||
            result.columns != draft.table.columns + draft.action.columnDelta) {
          throw const FormatException('편집한 표의 행·열과 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.tableMerge) {
        final editor = widget.pptxTableMerge ?? const PptxTableMergeEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('표 셀 병합을 편집할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxTableMerge(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.edit(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          table: draft.table,
          action: draft.action,
          range: draft.range,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.table.shapeId ||
            result.action != draft.action ||
            result.range != draft.range ||
            result.rows != draft.table.rows ||
            result.columns != draft.table.columns) {
          throw const FormatException('편집한 표의 병합 영역과 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.speakerNotes) {
        final editor =
            widget.pptxSpeakerNotes ?? const PptxSpeakerNotesEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('발표자 노트를 편집할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxSpeakerNotes(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.edit(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          text: draft.text,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex) {
          throw const FormatException('편집한 발표자 노트와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.shapeText ||
          action == _PptxSlideEdit.shapeTextFormat ||
          action == _PptxSlideEdit.shapeParagraphAlignment) {
        final editor = widget.pptxShapeText ?? const PptxShapeTextEngine();
        final aligning = action == _PptxSlideEdit.shapeParagraphAlignment;
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('텍스트를 수정할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxShapeText(
          context,
          plan,
          (index) =>
              (aligning ? editor.inspectAlignmentSlide : editor.inspectSlide)(
                sourcePath: source.path,
                plan: plan,
                slideIndex: index,
              ),
          formatOnly: action == _PptxSlideEdit.shapeTextFormat,
          alignmentOnly: aligning,
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final format = draft.format;
        final alignment = draft.alignment;
        final result = await switch ((alignment, format)) {
          (final alignment?, _) => editor.align(
            sourcePath: source.path,
            plan: plan,
            outputPath: output.path,
            slideIndex: draft.slideIndex,
            shape: draft.shape,
            alignment: alignment,
          ),
          (_, final format?) => editor.format(
            sourcePath: source.path,
            plan: plan,
            outputPath: output.path,
            slideIndex: draft.slideIndex,
            shape: draft.shape,
            format: format,
          ),
          _ => editor.replace(
            sourcePath: source.path,
            plan: plan,
            outputPath: output.path,
            slideIndex: draft.slideIndex,
            shape: draft.shape,
            changes: draft.changes,
          ),
        };
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.shape.shapeId) {
          throw const FormatException('수정한 도형과 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.shapeGeometry) {
        final editor =
            widget.pptxShapeGeometry ?? const PptxShapeGeometryEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('위치와 크기를 수정할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxShapeGeometry(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.replace(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          shape: draft.shape,
          geometry: draft.geometry,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.shape.shapeId ||
            result.geometry != draft.geometry) {
          throw const FormatException('수정한 개체의 위치와 크기를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.shapeOrder) {
        final editor = widget.pptxShapeOrder ?? const PptxShapeOrderEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('개체 순서를 바꿀 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxShapeOrder(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.apply(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          shapeId: draft.shapeId,
          direction: draft.direction,
          fromIndex: draft.fromIndex,
          shapeCount: draft.shapeCount,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slides.length ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.shapeId ||
            result.fromIndex != draft.fromIndex ||
            result.toIndex !=
                draft.direction.destination(
                  draft.fromIndex,
                  draft.shapeCount,
                )) {
          throw const FormatException('변경한 개체의 순서를 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.shapeDelete) {
        final editor = widget.pptxShapeDelete ?? const PptxShapeDeleteEngine();
        final plan = await editor.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('도형을 삭제할 PPTX 원본이 바뀌었습니다.');
        }
        final draft = await choosePptxShapeToDelete(
          context,
          plan,
          (index) => editor.inspectSlide(
            sourcePath: source.path,
            plan: plan,
            slideIndex: index,
          ),
        );
        if (draft == null || !current()) return;
        await requireLatestSource();
        final result = await editor.delete(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: draft.slideIndex,
          shapeId: draft.shapeId,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != draft.slideIndex ||
            result.shapeId != draft.shapeId) {
          throw const FormatException('삭제한 도형과 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.layout) {
        final layout = widget.pptxSlideLayout ?? const PptxSlideLayoutEngine();
        final plan = await layout.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('레이아웃을 변경할 PPTX 원본이 바뀌었습니다.');
        }
        if (!plan.slides.any((slide) => slide.layouts.isNotEmpty)) {
          throw const FormatException('이 PPTX에 적용할 수 있는 호환 레이아웃이 없습니다.');
        }
        final choice = await choosePptxSlideLayout(context, plan);
        if (choice == null || !current()) return;
        await requireLatestSource();
        final result = await layout.apply(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: choice.index,
          layoutId: choice.layoutId,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount ||
            result.slideIndex != choice.index ||
            result.slideId != plan.slides[choice.index].slideId ||
            result.layoutId != choice.layoutId) {
          throw const FormatException('변경한 슬라이드와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      } else if (action == _PptxSlideEdit.insert) {
        final inserter =
            widget.pptxSlideInsert ?? const PptxSlideInsertEngine();
        final plan = await inserter.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('슬라이드를 추가할 PPTX 원본이 바뀌었습니다.');
        }
        if (plan.slideCount >= PptxSlideInsertEngine.maxSlides) {
          throw const FormatException('PPTX에는 슬라이드를 최대 256개까지 저장할 수 있습니다.');
        }
        if (!plan.slides.any((slide) => slide.canInsert)) {
          throw const FormatException('이 PPTX에는 빈 슬라이드를 추가할 수 있는 위치가 없습니다.');
        }
        final choice = await choosePptxSlideToInsert(context, plan);
        if (choice == null || !current()) return;
        await requireLatestSource();
        final result = await inserter.insert(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: choice.index,
          layoutId: choice.layoutId,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount + 1 ||
            result.insertedIndex != choice.index + 1 ||
            result.layoutId != choice.layoutId) {
          throw const FormatException('추가한 슬라이드의 위치와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
        if (choice.layoutId != null) completedAction = '선택한 레이아웃으로 슬라이드를 추가';
      } else {
        final deleter = widget.pptxSlideDelete ?? const PptxSlideDeleteEngine();
        final plan = await deleter.inspect(
          sourcePath: source.path,
          sourceSha256: selected.originalSha256,
        );
        if (!mounted || !current()) return;
        if (plan.sourceSha256 != selected.originalSha256) {
          throw const FormatException('삭제할 PPTX 원본이 바뀌었습니다.');
        }
        if (plan.slideCount < 2) {
          throw const FormatException('마지막 슬라이드는 삭제할 수 없습니다.');
        }
        if (!plan.slides.any((slide) => slide.canDelete)) {
          throw const FormatException('이 PPTX에는 삭제할 수 있는 슬라이드가 없습니다.');
        }
        final index = await choosePptxSlideToDelete(context, plan);
        if (index == null || !current()) return;
        await requireLatestSource();
        final result = await deleter.delete(
          sourcePath: source.path,
          plan: plan,
          outputPath: output.path,
          slideIndex: index,
        );
        requireCurrent();
        if (result.sourceSha256 != selected.originalSha256 ||
            result.outputSha256 == result.sourceSha256 ||
            result.slideCount != plan.slideCount - 1 ||
            result.deletedIndex != index) {
          throw const FormatException('삭제한 슬라이드와 PPTX 판본을 확인하지 못했습니다.');
        }
        outputSha256 = result.outputSha256;
        slideCount = result.slideCount;
      }
      final length = await output.length();
      if (length < 1 || length > 128 * 1024 * 1024) {
        throw const FormatException('편집한 PPTX의 크기를 확인하지 못했습니다.');
      }
      requireCurrent();
      final sessionId = newId();
      final OfficePreviewResult preview;
      if (windowsPreview != null) {
        if ((await sha256.bind(output.openRead()).first).toString() !=
            outputSha256) {
          throw const FormatException('편집한 PPTX의 파일 내용을 확인하지 못했습니다.');
        }
        requireCurrent();
        rendered = await windowsPreview.preview(
          sourcePath: output.path,
          sessionId: sessionId,
        );
        if (!current()) return;
        if (rendered == null) {
          throw const FormatException('편집한 PPTX의 PDF를 만들지 못했습니다.');
        }
        preview = rendered;
      } else {
        observation = await engine.inspectPresentation(
          sourcePath: output.path,
          sessionId: sessionId,
          inputSourceSha256: outputSha256,
        );
        if (observation == null || !current()) return;
        if (observation.sessionId != sessionId ||
            observation.format != 'pptx' ||
            observation.sourceSha256 != outputSha256) {
          throw const FormatException('편집한 PPTX를 다시 연 결과를 확인하지 못했습니다.');
        }
        if (observation.partCount != slideCount) {
          throw FormatException(
            '${action.slideCountLabel} 슬라이드 수와 PDF 쪽 수가 일치하지 않습니다.',
          );
        }
        preview = OfficePreviewResult(
          pdfPath: observation.pdfPath,
          pdfSha256: observation.pdfSha256,
          pageCount: observation.pageCount,
          sourceSha256: observation.sourceSha256,
          engineVersion: observation.engineVersion,
        );
      }
      if (preview.pageCount != slideCount) {
        throw FormatException(
          '${action.slideCountLabel} 슬라이드 수와 PDF 쪽 수가 일치하지 않습니다.',
        );
      }
      final bytes = await output.readAsBytes();
      if (bytes.length != length ||
          sha256.convert(bytes).toString() != outputSha256) {
        throw const FormatException('편집한 PPTX의 파일 내용을 확인하지 못했습니다.');
      }
      final pdf = await _readVerifiedOfficePreview(
        output,
        outputSha256,
        preview,
      );
      requireCurrent();
      final edition = await documents.commitEdited(
        captured,
        originalBytes: bytes,
        pdfBytes: pdf,
        engineVersion: preview.engineVersion,
        pageCount: preview.pageCount,
        requireCurrentHeads: true,
        beforePublish: requireCurrent,
      );
      if (!current()) return;
      setState(() {
        _selectPublishedEdition(edition);
        _editions = [edition.summary, ..._editions];
        _sourceHeads = {edition.revision.revisionId};
      });
      final viewSaved = await _rememberView(
        successNotice: '$completedAction하고 새 원본과 PDF를 저장했습니다.',
      );
      if (!_current(generation)) return;
      try {
        await _refreshEditions();
      } catch (_) {
        if (viewSaved && _current(generation)) {
          setState(() {
            _notice = '$completedAction했습니다. 판본 목록을 다시 열어 확인하세요.';
          });
        }
      }
    } finally {
      try {
        if (rendered != null) {
          await rendered.dispose();
        } else {
          await observation?.dispose();
        }
      } finally {
        for (final file in [source, output, ?asset]) {
          try {
            if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
                FileSystemEntityType.file) {
              await file.delete();
            }
          } on FileSystemException {
            // The native preview may still be closing this draft.
          }
        }
        try {
          if (FileSystemEntity.typeSync(work.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            await work.delete();
          }
        } on FileSystemException {
          // Preserve a working folder with a file still owned by the preview.
        }
      }
    }
  }

  Future<void> _launchWindowsEdit() {
    final pending = _windowsPreparation;
    if (pending != null) return pending;
    if (_windowsRoute != null || !_canEdit) return Future.value();
    late Future<void> tracked;
    tracked = _prepareWindowsEdit().whenComplete(() {
      if (identical(_windowsPreparation, tracked)) _windowsPreparation = null;
      if (mounted) {
        _report();
        setState(() {});
      }
    });
    _windowsPreparation = tracked;
    _report();
    if (mounted) setState(() {});
    return tracked;
  }

  Future<void> _prepareWindowsEdit() async {
    final selected = _edition;
    if (selected == null) return;
    final generation = _generation;
    final engine = _structuredEngine;
    final hwp = _useHwp;
    final captured = await _documents.beginEdit(
      widget.note,
      revisionId: selected.revision.revisionId,
    );
    if (!_current(generation)) return;
    final sessionId = newId();
    final working = FileManager.getFile(
      '/.working/office/${widget.note.id}/${selected.revision.revisionId}/$sessionId/original${p.extension(captured.originalFileName)}',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(captured.originalBytes, flush: true);
    final snapshot = await engine.inspect(working.path, preview: true);
    final preview = File(p.join(working.parent.path, 'initial-preview.pdf'));
    try {
      if (snapshot.sourceSha256 !=
              sha256.convert(captured.originalBytes).toString() ||
          sha256.convert(await working.readAsBytes()).toString() !=
              snapshot.sourceSha256) {
        throw const FormatException('원본 미리보기가 선택한 문서와 일치하지 않습니다.');
      }
      final initialPreview = File(snapshot.previewPdfPath!);
      if (!p.isAbsolute(initialPreview.path) ||
          FileSystemEntity.typeSync(initialPreview.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await initialPreview.length() > 128 * 1024 * 1024) {
        throw const FormatException('원본 미리보기 파일을 확인하지 못했습니다.');
      }
      await preview.writeAsBytes(
        await initialPreview.readAsBytes(),
        flush: true,
      );
    } finally {
      await snapshot.disposePreview();
    }
    if (!_current(generation)) return;
    await _saveAnnotations();
    if (!_current(generation)) return;
    final session = _WindowsEditingSession(
      captured,
      sessionId,
      generation,
      working.path,
      snapshot,
      engine,
    );
    final key = GlobalKey<WindowsOfficeEditorState>();
    _windowsSession = session;
    _windowsEditorKey = key;
    setState(() {
      _pdfMode = false;
      _annotation = null;
      _editorKey = GlobalKey();
      _editorBusy = false;
      _editorDirty = false;
      _error = null;
      _notice = null;
      _recoveryPath = working.parent.path;
    });
    _report();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    late MaterialPageRoute<void> route;
    route = MaterialPageRoute<void>(
      builder: (_) => WindowsOfficeEditor(
        key: key,
        snapshot: snapshot,
        previewPath: preview.path,
        allowFormatting: !hwp,
        allowedTextStyleProperties: hwp
            ? const {'bold', 'italic', 'underline', 'fontSize', 'color'}
            : null,
        allowParagraphAlignment: hwp,
        allowHwpTableStructure: hwp && _canEditCurrentSource,
        allowHwpParagraphDeletion: hwp && _canEditCurrentSource,
        previewNotice: hwp
            ? '미리보기에는 포함된 한글 글꼴을 사용하므로 원본과 줄바꿈·모양이 다를 수 있습니다. 문단·표 셀의 글자, 지원되는 선택 글자 서식과 문단 정렬을 편집할 수 있으며, 복잡한 구조는 지원하지 않습니다.'
            : null,
        onDirtyChanged: (dirty) {
          if (_current(generation) && identical(_windowsSession, session)) {
            _nativeDirty = dirty;
            _report();
          }
        },
        onCommit: (operations) => _commitWindows(session, operations),
        onCommitWithAssets: hwp
            ? null
            : (operations, images) =>
                  _commitWindows(session, operations, imageAssets: images),
        onPreview:
            !hwp &&
                ((snapshot.kind == 'presentation' &&
                        snapshot.masters != null) ||
                    (snapshot.kind == 'word' &&
                        snapshot.blocks != null &&
                        snapshot.wordOwners != null &&
                        snapshot.pageStyles != null))
            ? (operations, images) =>
                  _previewWindows(session, operations, images)
            : null,
        onBack: () async {
          if (route.isCurrent)
            navigator.pop();
          else if (route.isActive)
            navigator.removeRoute(route);
          await route.popped;
          await route.completed;
        },
      ),
    );
    _windowsRoute = route;
    navigator.push<void>(route);
    final closed = route.completed.then<void>((_) {});
    _windowsRouteDone = closed;
    unawaited(
      closed.then((_) {
        unawaited(session.close());
        if (!identical(_windowsRoute, route)) return;
        _windowsRoute = null;
        _windowsRouteDone = null;
        _windowsEditorKey = null;
        _windowsSession = null;
        if (_current(generation)) {
          _nativeDirty = false;
          _report();
          setState(() {});
        }
      }),
    );
  }

  String _windowsStructureOperationsHash(
    List<WindowsOfficeOperation> operations,
  ) {
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: canonical(value[key])};
      }
      if (value is List) return [for (final item in value) canonical(item)];
      return value;
    }

    return sha256
        .convert(
          utf8.encode(
            jsonEncode(
              canonical([
                for (final operation in operations) operation.toJson(),
              ]),
            ),
          ),
        )
        .toString();
  }

  String _windowsSignature(
    _WindowsEditingSession session,
    List<WindowsOfficeOperation> operations,
    Map<String, WindowsOfficeImageAsset> images,
  ) {
    final ids = images.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'baseSourceSha256': session.snapshot.sourceSha256,
              'operations': [
                for (final operation in operations) operation.toJson(),
              ],
              'images': {for (final id in ids) id: images[id]!.sha256},
            }),
          ),
        )
        .toString();
  }

  Future<WindowsOfficeDraftPreview> _previewWindows(
    _WindowsEditingSession session,
    List<WindowsOfficeOperation> operations,
    Map<String, WindowsOfficeImageAsset> images,
  ) {
    if (_windowsPreview != null || _windowsCommit != null) {
      throw StateError('문서 작업을 마친 뒤 다시 시도하세요.');
    }
    final capturedOperations = List<WindowsOfficeOperation>.unmodifiable(
      operations,
    );
    final capturedImages = Map<String, WindowsOfficeImageAsset>.unmodifiable(
      images,
    );
    final signature = _windowsSignature(
      session,
      capturedOperations,
      capturedImages,
    );
    late Future<WindowsOfficeDraftPreview> tracked;
    tracked =
        _previewWindowsNow(
          session,
          capturedOperations,
          capturedImages,
          signature,
        ).whenComplete(() {
          if (identical(_windowsPreview, tracked)) _windowsPreview = null;
          if (mounted) {
            _report();
            setState(() {});
          }
        });
    _windowsPreview = tracked;
    session.outputOperation = tracked.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _report();
    return tracked;
  }

  Future<WindowsOfficeDraftPreview> _previewWindowsNow(
    _WindowsEditingSession session,
    List<WindowsOfficeOperation> operations,
    Map<String, WindowsOfficeImageAsset> images,
    String signature,
  ) async {
    bool current() =>
        !session.closed &&
        _current(session.generation) &&
        identical(_windowsSession, session);
    if (!current() || session.committedEdition != null)
      throw StateError('이 편집 세션의 미리보기를 만들 수 없습니다.');
    final sourceStructure =
        operations.isNotEmpty &&
        operations.every(
          (op) => op.toJson()['op'] == 'presentationSourceTableAdd',
        );
    final operationHash = sourceStructure
        ? _windowsStructureOperationsHash(operations)
        : null;
    bool matchesDraft(WindowsOfficeEditResult value) {
      if (sourceStructure) {
        final proof = value.structuralPreview;
        return images.isEmpty &&
            value.draftSnapshot == null &&
            proof != null &&
            proof.baseSourceSha256 == session.snapshot.sourceSha256 &&
            proof.candidateSourceSha256 == value.sourceSha256 &&
            proof.snapshot.sourceSha256 == value.sourceSha256 &&
            proof.snapshot.kind == session.snapshot.kind &&
            proof.operationsSha256 == operationHash;
      }
      return value.structuralPreview == null &&
          value.draftSnapshot?.sourceSha256 == session.snapshot.sourceSha256 &&
          value.draftSnapshot?.kind == session.snapshot.kind;
    }

    var result = session.previewLease?.result;
    if (result == null || session.previewSignature != signature) {
      final lease = await session.engine.preview(
        session.workingPath,
        operations: operations,
        imageAssets: images,
        sessionId: session.id,
        expectedSourceSha256: session.snapshot.sourceSha256,
      );
      result = lease.result;
      if (!current() ||
          !matchesDraft(result) ||
          p.extension(result.sourcePath).toLowerCase() !=
              p.extension(session.captured.originalFileName).toLowerCase()) {
        await lease.dispose();
        throw StateError('다른 문서의 미리보기는 사용하지 않았습니다.');
      }
      final retired = session.retiredPreview;
      session.retiredPreview = session.previewLease;
      session.previewLease = lease;
      session.previewSignature = signature;
      await retired?.dispose();
    }
    if (!current() || !matchesDraft(result))
      throw StateError('문서 전환 후 미리보기를 사용하지 않았습니다.');
    session.pendingResult = result;
    session.pendingSignature = signature;
    return WindowsOfficeDraftPreview(
      snapshot: sourceStructure
          ? result.structuralPreview!.snapshot
          : result.draftSnapshot!,
      pdfPath: result.pdfPath,
      signature: signature,
      baseSourceSha256: session.snapshot.sourceSha256,
      structuralPreview: sourceStructure ? result.structuralPreview : null,
    );
  }

  Future<void> _commitWindows(
    _WindowsEditingSession session,
    List<WindowsOfficeOperation> operations, {
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
  }) {
    final pending = _windowsCommit;
    if (pending != null) return pending;
    late Future<void> tracked;
    tracked =
        (() async {
              final preview = _windowsPreview;
              if (preview != null) await preview;
              await _commitWindowsNow(
                session,
                operations,
                imageAssets: imageAssets,
              );
            })()
            .catchError((Object error, StackTrace trace) {
              try {
                final preview = session.previewLease;
                if (preview != null &&
                    identical(preview.result, session.pendingResult)) {
                  preview.retainForRecovery();
                }
              } on StateError {
                /* The original save error takes precedence. */
              }
              if (_current(session.generation) &&
                  identical(_windowsSession, session)) {
                final result = session.pendingResult;
                if (result != null)
                  _recoveryPath = p.dirname(result.sourcePath);
              }
              Error.throwWithStackTrace(error, trace);
            })
            .whenComplete(() {
              if (identical(_windowsCommit, tracked)) _windowsCommit = null;
              if (mounted) {
                _report();
                setState(() {});
              }
            });
    _windowsCommit = tracked;
    session.outputOperation = tracked.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _report();
    return tracked;
  }

  Future<void> _commitWindowsNow(
    _WindowsEditingSession session,
    List<WindowsOfficeOperation> operations, {
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
  }) async {
    bool current() =>
        !session.closed &&
        _current(session.generation) &&
        identical(_windowsSession, session);
    if (!current()) throw StateError('다른 문서로 전환되어 이 편집 결과는 저장할 수 없습니다.');
    var edition = session.committedEdition;
    if (edition == null) {
      final deletesHwpParagraph =
          session.engine is HwpStructuredOfficeEngine &&
          operations.any(
            (operation) => operation.toJson()['op'] == 'paragraphDelete',
          );
      final editsHwpStructure =
          deletesHwpParagraph ||
          operations.any(
            (operation) => operation.toJson()['op'] == 'tableStructure',
          );
      if (editsHwpStructure) {
        final heads = await _documents.repository.heads(
          session.captured.sourceEntityId,
        );
        if (!current() ||
            heads.length != 1 ||
            heads.single.revisionId !=
                session.captured.parentRevisionIds.single) {
          throw StateError(
            deletesHwpParagraph
                ? '새 한글 판본을 받았습니다. 최신 판본에서 문단을 다시 선택하세요.'
                : '새 한글 판본을 받았습니다. 최신 판본에서 표를 다시 선택하세요.',
          );
        }
      }
      final signature = _windowsSignature(session, operations, imageAssets);
      var result = session.pendingResult;
      if (result == null || signature != session.pendingSignature) {
        result = await session.engine.apply(
          session.workingPath,
          operations: operations,
          sessionId: session.id,
          expectedSourceSha256: session.snapshot.sourceSha256,
          imageAssets: imageAssets,
        );
        session.pendingResult = result;
        session.pendingSignature = signature;
      }
      final source = File(result.sourcePath);
      final pdf = File(result.pdfPath);
      if (!p.isAbsolute(source.path) ||
          !p.isAbsolute(pdf.path) ||
          p.equals(source.path, session.workingPath) ||
          p.equals(source.path, pdf.path) ||
          !p.equals(p.dirname(source.path), p.dirname(pdf.path)) ||
          p.extension(source.path).toLowerCase() !=
              p.extension(session.captured.originalFileName).toLowerCase() ||
          p.extension(pdf.path).toLowerCase() != '.pdf' ||
          FileSystemEntity.typeSync(source.path, followLinks: false) !=
              FileSystemEntityType.file ||
          FileSystemEntity.typeSync(pdf.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await source.length() > 128 * 1024 * 1024 ||
          await pdf.length() > 128 * 1024 * 1024) {
        throw const FormatException('문서 편집 결과 파일을 안전하게 확인하지 못했습니다.');
      }
      final originalBytes = await source.readAsBytes();
      final pdfBytes = await pdf.readAsBytes();
      if (sha256.convert(originalBytes).toString() != result.sourceSha256 ||
          sha256.convert(pdfBytes).toString() != result.pdfSha256) {
        throw const FormatException(
          '문서 저장 파일의 무결성 검사에 실패했습니다. 편집 파일은 기기에 보관됩니다.',
        );
      }
      if (!current()) throw StateError('문서 전환 후 편집 결과를 저장하지 않았습니다.');
      edition = await _documents.commitEdited(
        session.captured,
        originalBytes: originalBytes,
        pdfBytes: pdfBytes,
        engineVersion: result.engineVersion,
        pageCount: result.pdfPageCount,
        requireCurrentHeads:
            editsHwpStructure ||
            operations.any(
              (operation) => operation.toJson()['op'] == 'slideDuplicate',
            ),
      );
      session.committedEdition = edition;
    }
    if (!current()) return;
    final savedEdition = edition;
    setState(() {
      _selectPublishedEdition(savedEdition);
      _editions = [
        savedEdition.summary,
        ..._editions.where(
          (old) => old.revision.revisionId != savedEdition.revision.revisionId,
        ),
      ];
      _sourceHeads = {
        ..._sourceHeads.difference(session.captured.parentRevisionIds.toSet()),
        savedEdition.revision.revisionId,
      };
      _recoveryPath = null;
    });
    final viewSaved = await _rememberView(successNotice: '원본과 PDF를 저장했습니다.');
    if (!current()) return;
    try {
      final editions = await _documents.readEditionSummaries(widget.note);
      final heads = await widget.repository.heads(widget.note.sourceEntityId!);
      if (!current()) return;
      setState(() {
        _editions = editions;
        _sourceHeads = heads.map((record) => record.revisionId).toSet();
      });
    } catch (_) {
      if (viewSaved && current())
        setState(
          () => _notice = '문서는 저장되었습니다. 기록 목록을 새로 읽지 못했습니다. 문서를 다시 열어 확인하세요.',
        );
    }
  }

  Future<void> _editInteractiveOriginal() async {
    final selected = _edition;
    if (selected == null) return;
    final generation = _generation;
    final documents = _documents;
    final recovery = _recovery;
    final engine = _windowsEngine;
    final note = widget.note;
    final captured = await documents.beginEdit(
      note,
      revisionId: selected.revision.revisionId,
    );
    if (!_current(generation)) return;
    final sessionId = newId();
    final working = FileManager.getFile(
      '/.working/office/${note.id}/${selected.revision.revisionId}/$sessionId/original${p.extension(captured.originalFileName)}',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(captured.originalBytes, flush: true);
    if (!_current(generation)) return;
    await _saveAnnotations();
    if (!_current(generation)) return;
    final entry = await recovery.start(
      captured,
      sessionId: sessionId,
      workingPath: working.path,
    );
    if (!_current(generation)) return;
    final editing = _WindowsInteractiveEditing(
      captured,
      sessionId,
      generation,
      working.path,
      engine,
      recovery,
      documents,
    );
    setState(() {
      _interactiveEditing = editing;
      _pdfMode = false;
      _annotation = null;
      _editorKey = GlobalKey();
      _editorBusy = false;
      _editorDirty = false;
      _nativeDirty = true;
      _error = null;
      _notice = null;
      _recoveryPath = working.parent.path;
      _recoveries = [
        entry,
        ..._recoveries.where((old) => old.sessionId != sessionId),
      ];
    });
    _report();
    await _runInteractiveEditing(editing);
  }

  Future<void> _runInteractiveEditing(
    _WindowsInteractiveEditing editing, {
    bool continuePreserved = false,
  }) async {
    WindowsOfficeInteractiveSession? native;
    try {
      native = await editing.engine.startInteractive(
        workingPath: editing.workingPath,
        sessionId: editing.id,
        inputSourceSha256: sha256
            .convert(editing.captured.originalBytes)
            .toString(),
      );
      editing.native = native;
      if (editing.cancellationRequested || !_current(editing.generation)) {
        await native.cancel();
      }
      final result = await native.result;
      editing.resultReceived = true;
      if (_current(editing.generation) &&
          identical(_interactiveEditing, editing)) {
        setState(() {});
      }
      await _acceptNativeResult(
        recovery: editing.recovery,
        documents: editing.documents,
        note: editing.captured.note,
        sessionId: editing.id,
        generation: editing.generation,
        workingPath: editing.workingPath,
        result: result,
        continuePreserved: continuePreserved,
        shouldPreserve: () => editing.cancellationRequested,
        onRecorded: native.releaseOutputs,
        onPublishing: () {
          editing.publicationStarted = true;
          if (_current(editing.generation) &&
              identical(_interactiveEditing, editing)) {
            setState(() {});
          }
        },
      );
    } catch (_) {
      if (_current(editing.generation) && _pendingNative == null) {
        _nativeDirty = false;
        _report();
      }
      rethrow;
    } finally {
      await native?.dispose();
      if (identical(_interactiveEditing, editing)) {
        _interactiveEditing = null;
        if (mounted) {
          _report();
          setState(() {});
        }
      }
    }
  }

  Future<void> _cancelInteractiveEditing() async {
    final editing = _interactiveEditing;
    if (editing == null || editing.publicationStarted) return;
    final cancellation = editing.cancel();
    if (mounted) setState(() {});
    await cancellation;
  }

  Future<void> _editOriginal() async {
    final selected = _edition;
    if (selected == null) return;
    final generation = _generation;
    final documents = _documents;
    final recovery = _recovery;
    final engine = _engine;
    final note = widget.note;
    final captured = await documents.beginEdit(
      note,
      revisionId: selected.revision.revisionId,
    );
    if (!_current(generation)) return;
    final sessionId = newId();
    final extension = p.extension(captured.originalFileName);
    final working = FileManager.getFile(
      '/.working/office/${note.id}/${selected.revision.revisionId}/$sessionId/original$extension',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(captured.originalBytes, flush: true);
    if (!_current(generation)) return;
    await _saveAnnotations();
    if (!_current(generation)) return;
    final entry = await recovery.start(
      captured,
      sessionId: sessionId,
      workingPath: working.path,
    );
    if (!_current(generation)) return;
    setState(() {
      _pdfMode = false;
      _annotation = null;
      _editorKey = GlobalKey();
      _editorBusy = false;
      _editorDirty = false;
      _nativeDirty = true;
      _error = null;
      _notice = null;
      _recoveryPath = working.parent.path;
      _recoveries = [
        entry,
        ..._recoveries.where((old) => old.sessionId != sessionId),
      ];
    });
    _report();
    try {
      final result = await engine.edit(
        sourcePath: working.path,
        sessionId: sessionId,
      );
      await _acceptNativeResult(
        recovery: recovery,
        documents: documents,
        note: note,
        sessionId: sessionId,
        generation: generation,
        workingPath: working.path,
        result: result,
      );
    } catch (_) {
      if (_current(generation) && _pendingNative == null) {
        _nativeDirty = false;
        _report();
      }
      rethrow;
    }
  }

  Future<void> _acceptNativeResult({
    required OfficeEditRecoveryStore recovery,
    required OfficeDocumentStore documents,
    required VaultNote note,
    required String sessionId,
    required int generation,
    required String workingPath,
    required AndroidOfficeEditResult result,
    bool continuePreserved = false,
    bool Function()? shouldPreserve,
    Future<void> Function()? onRecorded,
    VoidCallback? onPublishing,
  }) async {
    if (result.status == AndroidOfficeEditStatus.cancelled) {
      await recovery.preserve(note, sessionId);
      if (!_current(generation)) return;
      final entries = await recovery.list(note);
      if (!_current(generation)) return;
      setState(() {
        _nativeDirty = false;
        _notice = '원본 편집을 취소했습니다.';
        _recoveries = entries;
      });
      _report();
      return;
    }
    final OfficeEditRecoveryEntry saved;
    try {
      saved = await recovery.recordNativeSaved(note, sessionId, result);
    } on FormatException {
      throw const FormatException(
        '문서 저장 파일의 무결성 검사에 실패했습니다. 수정 파일은 기기에 보관됩니다.',
      );
    }
    await onRecorded?.call();
    Future<void> preserveRecorded() async {
      await recovery.preserve(note, sessionId);
      if (!_current(generation)) return;
      final entries = await recovery.list(note);
      if (!_current(generation)) return;
      setState(() {
        _recoveries = entries;
        _nativeDirty = false;
        _notice = '편집 결과를 보관했습니다. 이어 저장을 누르면 원본에 반영됩니다.';
      });
      _report();
    }

    if (shouldPreserve?.call() == true) {
      await preserveRecorded();
      return;
    }
    if (!_current(generation)) return;
    setState(() {
      _recoveries = [
        saved,
        ..._recoveries.where((entry) => entry.sessionId != sessionId),
      ];
    });
    if (saved.stage == OfficeEditRecoveryStage.preserved &&
        !continuePreserved) {
      final entries = await recovery.list(note);
      if (!_current(generation)) return;
      setState(() {
        _recoveries = entries;
        _nativeDirty = false;
        _notice = '편집 결과를 보관했습니다. 보관한 편집 작업에서 이어 저장할 수 있습니다.';
      });
      _report();
      return;
    }
    final restored = await recovery.read(note, sessionId);
    if (shouldPreserve?.call() == true) {
      await preserveRecorded();
      return;
    }
    if (!_current(generation)) return;
    onPublishing?.call();
    _pendingNative = _PendingNative(
      restored.session,
      restored.nativeResult!,
      sessionId,
      generation,
      workingPath,
      recovery,
      documents,
      preparedEdition: restored.preparedEdition,
    );
    _nativeDirty = true;
    _report();
    await _commitPending();
  }

  Future<void> _runRecovery(Future<void> Function() action) {
    final current = _recoveryOperation;
    if (current != null) return current;
    if (_busy) return Future.value();
    final generation = _generation;
    late Future<void> tracked;
    tracked = action().whenComplete(() {
      if (identical(_recoveryOperation, tracked)) _recoveryOperation = null;
      if (_current(generation)) {
        _report();
        setState(() {});
      }
    });
    _recoveryOperation = tracked;
    _report();
    if (mounted) setState(() {});
    return tracked;
  }

  Future<void> _continueRecovery(OfficeEditRecoveryEntry entry) async {
    if (!entry.canResume) throw StateError('문서의 원본 연결이 바뀌었습니다. 보관한 파일을 확인하세요.');
    if (!_liveNote) throw StateError('살아 있는 원본 문서에서 편집 작업을 이어가세요.');
    if (_pendingNative != null) throw StateError('먼저 현재 편집 결과를 저장하거나 보관하세요.');
    final generation = _generation;
    final recovery = _recovery;
    final documents = _documents;
    final note = widget.note;
    final engine = _engine;
    await _saveAnnotations();
    if (!_current(generation)) return;
    final restored = await recovery.read(note, entry.sessionId);
    if (!_current(generation) || !restored.entry.canResume) return;
    setState(() {
      _pdfMode = false;
      _annotation = null;
      _editorKey = GlobalKey();
      _editorBusy = false;
      _editorDirty = false;
      _error = null;
      _notice = null;
      _nativeDirty = true;
      _recoveryPath = p.dirname(
        restored.entry.sourcePath ?? restored.entry.workingPath,
      );
    });
    _report();
    try {
      final retainedResult = restored.nativeResult;
      if (retainedResult != null) {
        final extension = p
            .extension(restored.session.originalFileName)
            .toLowerCase();
        if (!_useWindows && (extension == '.doc' || extension == '.ppt')) {
          await engine.validateLegacySource(
            sourcePath: retainedResult.sourcePath!,
            format: extension.substring(1),
            sourceSha256: retainedResult.sourceSha256!,
          );
          if (!_current(generation)) return;
        }
        _pendingNative = _PendingNative(
          restored.session,
          retainedResult,
          entry.sessionId,
          generation,
          restored.entry.workingPath,
          recovery,
          documents,
          preparedEdition: restored.preparedEdition,
        );
        await _commitPending();
        return;
      }
      final inputHash = sha256
          .convert(restored.session.originalBytes)
          .toString();
      if (_useWindows && _interactiveAvailable && !_useHwp) {
        final editing = _WindowsInteractiveEditing(
          restored.session,
          entry.sessionId,
          generation,
          restored.entry.workingPath,
          _windowsEngine,
          recovery,
          documents,
        );
        setState(() => _interactiveEditing = editing);
        await _runInteractiveEditing(editing, continuePreserved: true);
        return;
      }
      final native = await engine.recoverSession(
        sessionId: entry.sessionId,
        inputSourceSha256: inputHash,
      );
      if (native.sessionId != entry.sessionId ||
          native.inputSourceSha256 != inputHash)
        throw const FormatException('이 문서에 연결된 원본 편집 작업이 아닙니다.');
      final AndroidOfficeEditResult result;
      if (native.status == AndroidOfficeRecoveryStatus.saved) {
        result = native.savedResult!;
      } else if (native.status == AndroidOfficeRecoveryStatus.working) {
        if (!_current(generation)) return;
        result = await engine.resumeSession(
          sessionId: entry.sessionId,
          inputSourceSha256: inputHash,
        );
      } else {
        if (!_current(generation)) return;
        final working = File(restored.entry.workingPath);
        if (FileSystemEntity.typeSync(working.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await working.length() > 128 * 1024 * 1024 ||
            sha256.convert(await working.readAsBytes()).toString() != inputHash)
          throw const FormatException(
            '기존 원본 작업 파일을 확인하지 못했습니다. 보관한 파일과 원본은 유지됩니다.',
          );
        if (!_current(generation)) return;
        result = await engine.edit(
          sourcePath: working.path,
          sessionId: entry.sessionId,
        );
      }
      await _acceptNativeResult(
        recovery: recovery,
        documents: documents,
        note: note,
        sessionId: entry.sessionId,
        generation: generation,
        workingPath: restored.entry.workingPath,
        result: result,
        continuePreserved: true,
      );
    } catch (_) {
      if (_current(generation) && _pendingNative == null) {
        _nativeDirty = false;
        _report();
      }
      rethrow;
    }
  }

  Future<void> _preserveRecovery(OfficeEditRecoveryEntry entry) async {
    final generation = _generation;
    final recovery = _recovery;
    final note = widget.note;
    await recovery.preserve(note, entry.sessionId);
    final entries = await recovery.list(note);
    if (!_current(generation)) return;
    setState(() {
      _recoveries = entries;
      _notice = '편집 파일을 보관했습니다. 보관한 편집 작업에서 다시 이어갈 수 있습니다.';
    });
  }

  Future<void> _preservePending() async {
    final pending = _pendingNative;
    if (pending == null) return;
    await pending.recovery.preserve(pending.session.note, pending.sessionId);
    final entries = await pending.recovery.list(pending.session.note);
    if (!_current(pending.generation) || !identical(_pendingNative, pending))
      return;
    setState(() {
      _pendingNative = null;
      _nativeDirty = false;
      _recoveries = entries;
      _error = null;
    });
    _report();
  }

  Future<void> _commitPending() {
    final current = _commitOperation;
    if (current != null) return current;
    final generation = _generation;
    _commitGeneration = generation;
    late Future<void> tracked;
    tracked = _commitPendingNow().whenComplete(() async {
      try {
        while (_current(generation) &&
            identical(_commitOperation, tracked) &&
            _refreshAfterCommit) {
          _refreshAfterCommit = false;
          await _run(_refreshOfficeWorkspace);
        }
      } finally {
        if (identical(_commitOperation, tracked)) {
          _commitOperation = null;
          _commitGeneration = null;
        }
        if (mounted) {
          _report();
          setState(() {});
        }
      }
    });
    _commitOperation = tracked;
    _report();
    return tracked;
  }

  Future<void> _commitPendingNow() async {
    final pending = _pendingNative;
    if (pending == null) return;
    if (!_current(pending.generation))
      throw StateError('이전 문서의 편집 결과를 현재 문서에 저장할 수 없습니다.');
    var prepared = pending.preparedEdition;
    if (prepared == null) {
      final result = pending.result;
      final hash = RegExp(r'^[0-9a-f]{64}$');
      if (result.status != AndroidOfficeEditStatus.saved ||
          result.sessionId != pending.sessionId ||
          result.inputSourceSha256 !=
              sha256.convert(pending.session.originalBytes).toString() ||
          result.engineVersion.trim().isEmpty ||
          result.sourcePath == null ||
          result.pdfPath == null ||
          result.sourceSha256 == null ||
          result.pdfSha256 == null ||
          !hash.hasMatch(result.sourceSha256!) ||
          !hash.hasMatch(result.pdfSha256!) ||
          result.pdfPageCount == null ||
          result.pdfPageCount! < 1)
        throw const FormatException('문서 저장 결과의 무결성을 확인하지 못했습니다.');
      final source = File(result.sourcePath!);
      final pdf = File(result.pdfPath!);
      if (!p.isAbsolute(source.path) ||
          !p.isAbsolute(pdf.path) ||
          p.equals(source.path, pdf.path) ||
          p.equals(source.path, pending.workingPath) ||
          !p.equals(p.dirname(source.path), p.dirname(pdf.path)) ||
          p.extension(source.path).toLowerCase() !=
              p.extension(pending.session.originalFileName).toLowerCase() ||
          p.extension(pdf.path).toLowerCase() != '.pdf')
        throw const FormatException('문서 저장 경로의 무결성을 확인하지 못했습니다.');
      if (FileSystemEntity.typeSync(source.path, followLinks: false) !=
              FileSystemEntityType.file ||
          FileSystemEntity.typeSync(pdf.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await source.length() > 128 * 1024 * 1024 ||
          await pdf.length() > 128 * 1024 * 1024)
        throw const FormatException('문서 저장 파일을 안전하게 확인하지 못했습니다.');
      if (result.sourceSha256 == result.inputSourceSha256 &&
          await pending.recovery.completeIfIdentical(
            pending.session.note,
            pending.sessionId,
          )) {
        if (!_current(pending.generation)) return;
        final recoveries = await pending.recovery.list(pending.session.note);
        if (!_current(pending.generation)) return;
        setState(() {
          _pendingNative = null;
          _nativeDirty = false;
          _recoveries = recoveries;
          _error = null;
          _notice = '이미 저장된 원본과 PDF를 유지했습니다.';
          _recoveryPath = null;
        });
        _report();
        return;
      }
      final originalBytes = await source.readAsBytes();
      final pdfBytes = await pdf.readAsBytes();
      if (sha256.convert(originalBytes).toString() != result.sourceSha256 ||
          sha256.convert(pdfBytes).toString() != result.pdfSha256)
        throw const FormatException(
          '문서 저장 파일의 무결성 검사에 실패했습니다. 수정 파일은 기기에 보관됩니다.',
        );
      if (!_current(pending.generation))
        throw StateError('문서 전환 후 편집 결과를 저장하지 않았습니다.');
      prepared = pending.documents.prepareEdited(
        pending.session,
        originalBytes: originalBytes,
        pdfBytes: pdfBytes,
        engineVersion: result.engineVersion,
        pageCount: result.pdfPageCount!,
      );
      pending.preparedEdition = prepared;
    }
    await pending.recovery.recordPrepared(
      pending.session.note,
      pending.sessionId,
      prepared,
    );
    if (!_current(pending.generation))
      throw StateError('문서 전환 후 편집 결과를 저장하지 않았습니다.');
    final edition = await pending.documents.commitPreparedEdition(prepared);
    await pending.recovery.complete(
      pending.session.note,
      pending.sessionId,
      edition,
    );
    if (!_current(pending.generation)) return;
    _pendingNative = null;
    _nativeDirty = false;
    final id = edition.revision.revisionId;
    setState(() {
      _selectPublishedEdition(edition);
      _editions = [
        edition.summary,
        ..._editions.where((old) => old.revision.revisionId != id),
      ];
      _sourceHeads = {
        ..._sourceHeads.difference(pending.session.parentRevisionIds.toSet()),
        id,
      };
      _recoveries = _recoveries
          .where((entry) => entry.sessionId != pending.sessionId)
          .toList();
      _recoveryPath = null;
    });
    _report();
    final viewSaved = await _rememberView(successNotice: '원본과 PDF를 저장했습니다.');
    if (!_current(pending.generation)) return;
    try {
      final editions = await pending.documents.readEditionSummaries(
        pending.session.note,
      );
      final heads = await pending.documents.repository.heads(
        pending.session.sourceEntityId,
      );
      final recoveries = await pending.recovery.list(pending.session.note);
      if (!_current(pending.generation)) return;
      setState(() {
        _editions = editions;
        _sourceHeads = heads.map((record) => record.revisionId).toSet();
        _recoveries = recoveries;
      });
    } catch (_) {
      if (viewSaved && _current(pending.generation)) {
        setState(() {
          _notice = '문서는 저장되었습니다. 기록 목록을 새로 읽지 못했습니다. 문서를 다시 열어 확인하세요.';
        });
      }
    }
  }

  Future<void> _openPdf({
    OfficePdfVariant? preview,
    String? annotationRevisionId,
    bool reloadingIncoming = false,
  }) => _transition(
    () => _openPdfNow(
      preview: preview,
      annotationRevisionId: annotationRevisionId,
      reloadingIncoming: reloadingIncoming,
    ),
  );

  Future<void> _carryPreviousPptxInk(
    OfficeEdition edition,
  ) => _transition(() async {
    if (_busy || _pdfMode || !identical(_edition, edition)) return;
    final generation = _generation;
    final note = widget.note;
    final repository = widget.repository;
    bool current() =>
        _current(generation) &&
        identical(widget.repository, repository) &&
        widget.note.revision.revisionId == note.revision.revisionId &&
        identical(_edition, edition);
    setState(() {
      _switching = true;
      _error = null;
      _notice = null;
    });
    _report();
    var copied = false;
    try {
      final result = await carryPreviousPptxAnnotations(
        repository: repository,
        note: note,
        edition: edition,
        isCurrent: current,
        slideIdentity:
            widget.pptxSlideIdentity ?? const PptxSlideIdentityEngine(),
      );
      if (!current()) return;
      copied = result.copiedPages > 0;
      setState(() {
        _notice = result.copiedPages == 0 && result.skippedPages == 0
            ? '바로 이전 판본에 가져올 필기가 없습니다.'
            : '${result.copiedPages}쪽의 필기를 가져왔습니다.'
                  '${result.skippedPages > 0 ? ' ${result.skippedPages}쪽은 이전 판본에서 볼 수 있습니다.' : ''}';
      });
    } finally {
      if (_current(generation)) {
        setState(() => _switching = false);
        _report();
      }
    }
    if (copied && current()) {
      final preview = _pdfVariants
          .where((variant) => variant.bindingId == edition.bindingId)
          .singleOrNull;
      if (preview == null) {
        throw StateError('필기는 저장했습니다. PDF 필기를 눌러 새 판본을 여세요.');
      }
      await _openPdfNow(preview: preview);
    }
  });

  Future<void> _chooseOriginalPageAnnotation(
    _OriginalPageConflict conflict,
  ) async {
    final generation = _generation;
    final remembered = _originalPreviewPage;
    final page =
        remembered != null &&
            _matchesOriginalVariant(remembered, conflict.preview)
        ? remembered
        : conflict.page;
    bool current() =>
        _current(generation) &&
        _originalPageConflict == conflict &&
        _matchesShownOriginalPage(page);
    if (!current() || _busy) return;
    final revisionId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('서로 다른 PDF 필기가 있습니다. 열 버전을 선택하세요.'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < conflict.heads.length; i++)
              TextButton(
                key: ValueKey(
                  'office-annotation-${conflict.heads[i].revisionId}',
                ),
                onPressed: () =>
                    Navigator.of(context).pop(conflict.heads[i].revisionId),
                child: Text('필기 버전 ${i + 1}'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
        ],
      ),
    );
    if (revisionId == null || !current() || _busy) return;
    await _transition(
      () => _openPdfNow(
        preview: conflict.preview,
        annotationRevisionId: revisionId,
        originalPage: page,
        expectedOriginalHeads: conflict.heads
            .map((head) => head.revisionId)
            .toSet(),
      ),
    );
  }

  Future<File> _materializePdf(
    String noteId,
    OfficePdfVariant preview,
    Uint8List bytes,
  ) async {
    // The immutable preview revision identifies the file without repeating its
    // digest in a path used by the Windows PDF reader.
    final pdf = FileManager.getFile(
      '/.working/office/$noteId/${preview.revision.revisionId}/preview.pdf',
    );
    await pdf.parent.create(recursive: true);
    if (!pdf.existsSync()) {
      final pending = File('${pdf.path}.${newId()}.pending');
      try {
        await pending.writeAsBytes(bytes, flush: true);
        try {
          await pending.rename(pdf.path);
        } on FileSystemException {
          if (!pdf.existsSync()) rethrow;
        }
      } finally {
        if (pending.existsSync()) await pending.delete();
      }
    }
    if ((await sha256.bind(pdf.openRead()).first).toString() !=
        preview.pdfSha256) {
      throw const FormatException('기기의 PDF 사본이 변경됐습니다. 원본은 보존되어 있습니다.');
    }
    return pdf;
  }

  Future<void> _openPdfNow({
    OfficePdfVariant? preview,
    String? annotationRevisionId,
    bool restoring = false,
    bool reloadingIncoming = false,
    _OriginalPdfPage? originalPage,
    Set<String>? expectedOriginalHeads,
  }) async {
    if (_switching) return;
    final edition = _edition;
    final selected = preview ?? _selectedPdf;
    if (edition == null ||
        selected == null ||
        selected.sourceRevisionId != edition.revision.revisionId)
      return;
    final generation = _generation;
    bool current() => _current(generation) && identical(_edition, edition);
    bool currentOriginalPage() =>
        current() &&
        originalPage != null &&
        _matchesShownOriginalPage(originalPage) &&
        _matchesOriginalVariant(originalPage, selected);
    EditorCoreInfo? snapshot;
    var transferred = false;
    setState(() => _switching = true);
    _report();
    try {
      if (originalPage != null ||
          _selectedPdf?.bindingId != selected.bindingId ||
          reloadingIncoming) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
      if (reloadingIncoming) {
        _captureViewPage();
        await _saveAnnotations();
        if (!current()) return;
      }
      final bytes = await _documents.readPdfVariantBytes(
        widget.note,
        edition,
        selected,
      );
      if (!current()) return;
      final pdf = await _materializePdf(widget.note.id, selected, bytes);
      if (!current()) return;
      final heads = await widget.repository.heads(selected.bindingId);
      if (!current()) return;
      final originalHeads = originalPage == null
          ? null
          : heads.map((head) => head.revisionId).toSet();
      if (expectedOriginalHeads != null &&
          (!setEquals(originalHeads, expectedOriginalHeads) ||
              !expectedOriginalHeads.contains(annotationRevisionId))) {
        setState(() => _originalPageConflict = null);
        throw const FormatException('필기 판본이 바뀌었습니다. PDF 필기를 다시 눌러 버전을 확인하세요.');
      }
      if (restoring &&
          (heads.length > 1 ||
              heads.any(
                (head) =>
                    head.deleted ||
                    head.vaultId != widget.repository.vaultId ||
                    head.ownerNoteId != widget.note.id ||
                    head.kind != EntityKind.ink,
              ))) {
        throw const FormatException('Ambiguous remembered PDF annotation');
      }
      OfficeAnnotationSession? annotation;
      if (heads.length < 2 || annotationRevisionId != null)
        annotation = await _annotations.open(
          widget.note,
          edition,
          preview: selected,
          revisionId: annotationRevisionId,
        );
      if (!current()) return;
      if (reloadingIncoming) {
        if (_editorDirty || _editorBusy) return;
      } else {
        await _saveAnnotations();
      }
      if (!current()) return;
      _OriginalPageReveal? reveal;
      if (originalPage != null) {
        if (!currentOriginalPage()) {
          throw const FormatException('미리보기와 같은 PDF 필기 버전을 찾을 수 없습니다.');
        }
        if (annotation == null) {
          setState(() {
            _originalPageConflict = (
              preview: selected,
              page: originalPage,
              heads: heads,
            );
            _error = null;
          });
          return;
        }
        final revision = annotation.revision?.revisionId;
        snapshot = await annotation.load();
        if (!currentOriginalPage()) return;
        final String pageId;
        if (revision == null) {
          final document = await snapshot.assetCache.pdfDocumentCache.load(
            pdf.path,
            pdfBytes: bytes,
          );
          if (!currentOriginalPage()) return;
          if (originalPage.number < 1 ||
              originalPage.number > document.pages.length) {
            throw const FormatException('필기용 PDF에 미리보기 페이지가 없습니다.');
          }
          pageId = officePdfBaselinePageId(
            selected.bindingId,
            originalPage.number - 1,
          );
        } else {
          final destination = await PdfImportPreparation.findBoundPage(
            snapshot,
            originalPage.number,
            pdfSha256: selected.pdfSha256,
            isCurrent: currentOriginalPage,
          );
          if (!currentOriginalPage()) return;
          if (destination == null) {
            throw const FormatException('미리보기와 일치하는 필기 페이지가 없거나 여러 개 있습니다.');
          }
          pageId = destination.pageId;
        }
        if (!await _originalAnnotationCurrent(
          annotation,
          revision,
          originalHeads!,
        )) {
          if (!currentOriginalPage()) return;
          setState(() => _originalPageConflict = null);
          throw const FormatException(
            '필기 판본이 바뀌었습니다. PDF 필기를 다시 눌러 버전을 확인하세요.',
          );
        }
        if (!currentOriginalPage()) return;
        reveal = (
          annotation: annotation,
          preview: selected,
          annotationRevisionId: revision,
          annotationHeadIds: originalHeads,
          pageId: pageId,
          previousPageId: _selectedPdf?.bindingId == selected.bindingId
              ? _viewPageId
              : null,
        );
      }
      setState(() {
        if (_selectedPdf?.bindingId != selected.bindingId) _viewPageId = null;
        _selectedPdf = selected;
        _selectedPdfBytes = bytes;
        _annotation = annotation;
        _annotationHeads = heads;
        _clearIncomingAnnotation();
        _incomingAnnotationSnapshot = snapshot;
        _originalPageReveal = reveal;
        _originalPageConflict = null;
        if (reveal != null) _viewPageId = reveal.pageId;
        _pdfPath = pdf.path;
        _pdfMode = true;
        _restoringView = restoring;
        _editorKey = GlobalKey();
        _editorDirty = false;
        _editorBusy = annotation != null;
        _annotationLoadFailed = false;
        _error = null;
      });
      transferred = snapshot != null;
      if (!restoring && reveal == null) await _rememberView();
    } finally {
      if (!transferred) snapshot?.dispose();
      if (_current(generation)) {
        setState(() => _switching = false);
        _report();
        if (_pdfMode) unawaited(_run(_refreshAnnotationView));
      }
    }
  }

  Widget _editionSelector() {
    final selected = _edition?.revision.revisionId;
    return DropdownButton<String>(
      key: const ValueKey('office-edition-selector'),
      isExpanded: true,
      value: _editions.any((item) => item.revision.revisionId == selected)
          ? selected
          : null,
      hint: const Text('버전 선택'),
      onChanged: _busy
          ? null
          : (id) {
              if (id != null) unawaited(_run(() => _selectEdition(id)));
            },
      items: [
        for (final (index, edition) in _editions.indexed)
          DropdownMenuItem(
            value: edition.revision.revisionId,
            child: Text(
              '기록 ${index + 1} · ${_editionDescription(edition)}'
              '${_sourceHeads.contains(edition.revision.revisionId) ? ' · 현재' : ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String _editionDescription(OfficeEditionSummary edition) {
    if (edition.metadataUnavailable) return '정보 확인 필요';
    if (!edition.hasPairedPdf) return '가져온 원본';
    final pages = edition.pageCount;
    return pages == null ? 'PDF' : '$pages쪽 PDF';
  }

  Widget _pdfVariantSelector() {
    final selected = _selectedPdf?.bindingId;
    return DropdownButton<String>(
      key: const ValueKey('office-pdf-variant-selector'),
      isExpanded: true,
      value: _pdfVariants.any((variant) => variant.bindingId == selected)
          ? selected
          : null,
      hint: const Text('PDF 버전 선택'),
      onChanged: _busy
          ? null
          : (id) {
              if (id == null || (_pdfMode && id == selected)) return;
              final preview = _pdfVariants
                  .where((variant) => variant.bindingId == id)
                  .singleOrNull;
              if (preview != null)
                unawaited(_run(() => _openPdf(preview: preview)));
            },
      items: [
        for (var i = 0; i < _pdfVariants.length; i++)
          DropdownMenuItem(
            value: _pdfVariants[i].bindingId,
            child: Text(
              'PDF 버전 ${i + 1} · ${_pdfVariants[i].pdfSha256.substring(0, 8)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _pptxTableStructureButton() => OutlinedButton.icon(
    key: const ValueKey('office-edit-pptx-table-structure'),
    onPressed: !_busy && _pendingNative == null
        ? () => unawaited(
            _run(() => _launchPptxSlideEdit(_PptxSlideEdit.tableStructure)),
          )
        : null,
    icon: const Icon(Icons.table_chart_outlined),
    label: const Text('표 행·열 편집'),
  );

  Widget _pptxSpeakerNotesButton() => OutlinedButton.icon(
    key: const ValueKey('office-edit-pptx-speaker-notes'),
    onPressed: !_busy && _pendingNative == null
        ? () => unawaited(
            _run(() => _launchPptxSlideEdit(_PptxSlideEdit.speakerNotes)),
          )
        : null,
    icon: const Icon(Icons.notes),
    label: const Text('발표자 노트'),
  );

  Widget _pptxTableMergeButton() => OutlinedButton.icon(
    key: const ValueKey('office-edit-pptx-table-merge'),
    onPressed: !_busy && _pendingNative == null
        ? () => unawaited(
            _run(() => _launchPptxSlideEdit(_PptxSlideEdit.tableMerge)),
          )
        : null,
    icon: const Icon(Icons.merge_type),
    label: const Text('표 셀 병합·해제'),
  );

  List<Widget> _originalEditActions() => [
    if (_canEditCurrentWindowsPptx) ...[
      const SizedBox(height: 8),
      _pptxTableStructureButton(),
      const SizedBox(height: 8),
      _pptxTableMergeButton(),
      const SizedBox(height: 8),
      _pptxSpeakerNotesButton(),
    ],
    if (_canEditCurrentWindowsPptx || _canEditCurrentAndroidPptx) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-find-replace'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.findReplace)),
              )
            : null,
        icon: const Icon(Icons.find_replace),
        label: const Text('찾아 바꾸기'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-shape-order'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.shapeOrder)),
              )
            : null,
        icon: const Icon(Icons.layers_outlined),
        label: const Text('개체 겹침 순서'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-align-pptx-shape-paragraph'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchPptxSlideEdit(
                    _PptxSlideEdit.shapeParagraphAlignment,
                  ),
                ),
              )
            : null,
        icon: const Icon(Icons.format_align_center),
        label: const Text('도형 문단 정렬'),
      ),
    ],
    if (_supportsDocxSourceEdit) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-docx-find-replace'),
        onPressed: _canEditCurrentSource && !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.docx', _SourceEdit.findReplace)),
              )
            : null,
        icon: const Icon(Icons.find_replace),
        label: const Text('찾아 바꾸기'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-docx-table-structure'),
        onPressed: _canEditCurrentSource && !_busy && _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit(
                    '.docx',
                    _SourceEdit.editTableStructure,
                  ),
                ),
              )
            : null,
        icon: const Icon(Icons.table_chart_outlined),
        label: const Text('표 행·열 편집'),
      ),
    ],
    if (_supportsAndroidSourceActions('.pptx')) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-replace-pptx-photo'),
        onPressed:
            _canEditCurrentAndroidPptx && !_busy && _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit('.pptx', _SourceEdit.replacePhoto),
                ),
              )
            : null,
        icon: const Icon(Icons.image_outlined),
        label: const Text('PPTX 사진 교체'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-delete-pptx-photo'),
        onPressed:
            _canEditCurrentAndroidPptx && !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.pptx', _SourceEdit.removePhoto)),
              )
            : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('PPTX 사진 삭제'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-rotate-pptx-photo'),
        onPressed:
            _canEditCurrentAndroidPptx && !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.pptx', _SourceEdit.rotatePhoto)),
              )
            : null,
        icon: const Icon(Icons.rotate_right),
        label: const Text('PPTX 사진 회전'),
      ),
    ],
    if (_supportsAndroidSourceActions('.docx')) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-docx-body-text'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit('.docx', _SourceEdit.replaceBodyText),
                ),
              )
            : null,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('본문 글자 수정'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-insert-docx-paragraph'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit('.docx', _SourceEdit.insertParagraph),
                ),
              )
            : null,
        icon: const Icon(Icons.add),
        label: const Text('본문 문단 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-insert-docx-table'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.docx', _SourceEdit.insertTable)),
              )
            : null,
        icon: const Icon(Icons.table_chart_outlined),
        label: const Text('표 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-docx-table-cell'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit('.docx', _SourceEdit.replaceCellText),
                ),
              )
            : null,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('표 셀 글자 수정'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-add-docx-photo'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.docx', _SourceEdit.insertPhoto)),
              )
            : null,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('DOCX 사진 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-replace-docx-photo'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchSourceEdit('.docx', _SourceEdit.replacePhoto),
                ),
              )
            : null,
        icon: const Icon(Icons.image_outlined),
        label: const Text('DOCX 사진 교체'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-delete-docx-photo'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.docx', _SourceEdit.removePhoto)),
              )
            : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('DOCX 사진 삭제'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-rotate-docx-photo'),
        onPressed:
            _canEditCurrentAndroidSource('.docx') &&
                !_busy &&
                _pendingNative == null
            ? () => unawaited(
                _run(() => _launchSourceEdit('.docx', _SourceEdit.rotatePhoto)),
              )
            : null,
        icon: const Icon(Icons.rotate_right),
        label: const Text('DOCX 사진 회전'),
      ),
    ],
    if (_canEditCurrentAndroidPptx) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-add-pptx-photo'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.photoAdd)),
              )
            : null,
        icon: const Icon(Icons.add),
        label: const Text('사진 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-insert-pptx-slide'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.insert)),
              )
            : null,
        icon: const Icon(Icons.add),
        label: const Text('슬라이드 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-change-pptx-slide-layout'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.layout)),
              )
            : null,
        icon: const Icon(Icons.view_quilt_outlined),
        label: const Text('슬라이드 레이아웃 변경'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-add-pptx-text-box'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.textBox)),
              )
            : null,
        icon: const Icon(Icons.text_fields),
        label: const Text('텍스트 상자 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-add-pptx-preset-shape'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.presetShape)),
              )
            : null,
        icon: const Icon(Icons.add_box_outlined),
        label: const Text('도형 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-add-pptx-table'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.tableAdd)),
              )
            : null,
        icon: const Icon(Icons.table_chart_outlined),
        label: const Text('표 추가'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-table-cell-text'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.tableCellText)),
              )
            : null,
        icon: const Icon(Icons.edit_note_outlined),
        label: const Text('표 셀 글자 수정'),
      ),
      const SizedBox(height: 8),
      _pptxTableStructureButton(),
      const SizedBox(height: 8),
      _pptxTableMergeButton(),
      const SizedBox(height: 8),
      _pptxSpeakerNotesButton(),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-shape-text'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.shapeText)),
              )
            : null,
        icon: const Icon(Icons.edit_note_outlined),
        label: const Text('도형 텍스트 수정'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-format-pptx-shape-text'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(
                  () => _launchPptxSlideEdit(_PptxSlideEdit.shapeTextFormat),
                ),
              )
            : null,
        icon: const Icon(Icons.text_fields),
        label: const Text('도형 글자 서식'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-shape-geometry'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.shapeGeometry)),
              )
            : null,
        icon: const Icon(Icons.open_in_full),
        label: const Text('개체 위치·크기'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-delete-pptx-shape'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.shapeDelete)),
              )
            : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('도형 삭제'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-duplicate-pptx-slide'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.duplicate)),
              )
            : null,
        icon: const Icon(Icons.control_point_duplicate),
        label: const Text('슬라이드 복제'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-reorder-pptx-slides'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.reorder)),
              )
            : null,
        icon: const Icon(Icons.swap_vert),
        label: const Text('슬라이드 순서 변경'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-display-pptx-slide'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.display)),
              )
            : null,
        icon: const Icon(Icons.visibility_outlined),
        label: const Text('발표에서 숨기기·표시'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-pptx-background'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.background)),
              )
            : null,
        icon: const Icon(Icons.format_color_fill_outlined),
        label: const Text('슬라이드 배경색'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-delete-pptx-slide'),
        onPressed: !_busy && _pendingNative == null
            ? () => unawaited(
                _run(() => _launchPptxSlideEdit(_PptxSlideEdit.delete)),
              )
            : null,
        icon: const Icon(Icons.delete_outline),
        label: const Text('슬라이드 삭제'),
      ),
    ],
    if (_useWindows && _interactiveAvailable && !_useHwp) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('office-edit-structured'),
        onPressed: _canEdit && !_busy && _pendingNative == null
            ? () => unawaited(_run(_launchWindowsEdit))
            : null,
        icon: const Icon(Icons.edit_note_outlined),
        label: const Text('항목별 편집'),
      ),
    ],
  ];

  Widget _originalInfo(OfficeEdition edition) {
    final preview = _selectedOriginalPreview;
    final shown = _shownOriginalPdf(edition);
    final editActions = _originalEditActions();
    final generation = _generation;
    final originalPage = _originalPreviewPage;
    final scope =
        '${widget.repository.root.absolute.uri.normalizePath()}'
        '${widget.repository.vaultId}/${widget.note.id}/'
        '${edition.revision.revisionId}/${shown?.sha256}';
    _OriginalPdfPage shownPage(int number) => (
      sourceRevisionId: edition.revision.revisionId,
      pdfSha256: shown!.sha256,
      bindingId: shown.bindingId,
      number: number,
    );
    bool current(_OriginalPdfPage page) =>
        _current(generation) &&
        identical(_edition, edition) &&
        _matchesShownOriginalPage(page);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (shown == null) ...[
                const Icon(Icons.description_outlined, size: 54),
                const SizedBox(height: 12),
              ],
              Text(
                edition.originalFileName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('office-preview-pdf'),
                    onPressed: _canPreview && !_busy && _pendingNative == null
                        ? () => unawaited(_run(_startPdfPreview))
                        : null,
                    icon: const Icon(Icons.draw_outlined),
                    label: const Text('PDF 필기 시작'),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('office-edit-original'),
                    onPressed: _canEdit && !_busy && _pendingNative == null
                        ? () => unawaited(_run(_launchEdit))
                        : null,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('원본 편집'),
                  ),
                  if (shown == null)
                    FilledButton.tonalIcon(
                      key: const ValueKey('office-original-preview-load'),
                      onPressed: _canPreview && !_busy && _pendingNative == null
                          ? () => unawaited(_run(_startOriginalPreview))
                          : null,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('원본 미리보기'),
                    ),
                ],
              ),
              if (shown != null) ...[
                const SizedBox(height: 16),
                OfficeOriginalPreview(
                  key: ValueKey(scope),
                  sourceKey: scope,
                  pdfBytes: shown.bytes,
                  initialPage: originalPage != null && current(originalPage)
                      ? originalPage.number
                      : 1,
                  onPageChanged: (number) {
                    final page = shownPage(number);
                    if (current(page)) _originalPreviewPage = page;
                  },
                  onAnnotatePage:
                      _canPreview && !_busy && _pendingNative == null
                      ? (number) {
                          final page = shownPage(number);
                          if (current(page)) {
                            unawaited(
                              _run(() => _startPdfPreview(originalPage: page)),
                            );
                          }
                        }
                      : null,
                  presentation: const {'.ppt', '.pptx'}.contains(
                    p.extension(edition.originalFileName).toLowerCase(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text('원본은 기기에 보관됩니다. 원본 편집을 저장하면 새 원본 버전과 PDF가 함께 추가됩니다.'),
              if (edition.originalFileName.toLowerCase().endsWith('.pptx') &&
                  edition.bindingId != null &&
                  edition.revision.parentRevisionIds.length == 1 &&
                  _sourceHeads.length == 1 &&
                  _sourceHeads.single == edition.revision.revisionId) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('office-carry-previous-pptx-ink'),
                  onPressed: !_busy && _pendingNative == null
                      ? () => unawaited(
                          _run(() => _carryPreviousPptxInk(edition)),
                        )
                      : null,
                  icon: const Icon(Icons.history_edu_outlined),
                  label: const Text('이전 판본에서 필기 가져오기'),
                ),
              ],
              if (_legacyCopyExtension case final target?
                  when _canMakeLegacyCopy) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('office-make-legacy-copy'),
                  onPressed: !_busy && _pendingNative == null
                      ? () => unawaited(_run(_makeLegacyCopy))
                      : null,
                  icon: const Icon(Icons.content_copy),
                  label: Text('${target.toUpperCase()} 편집용 복사본 만들기'),
                ),
              ],
              if (_useWindows)
                ...editActions
              else if (editActions.isNotEmpty)
                ExpansionTile(
                  key: const ValueKey('office-advanced-tools'),
                  title: const Text('세부 편집 도구'),
                  tilePadding: EdgeInsets.zero,
                  expandedAlignment: Alignment.centerLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: editActions,
                ),
              const SizedBox(height: 12),
              if (!_canEdit) const Text('이 기기에서는 이 형식의 원본 편집을 아직 사용할 수 없습니다.'),
              const SizedBox(height: 20),
              Text(
                edition.pdfBytes != null
                    ? '이 버전의 PDF ${edition.pageCount}쪽이 준비되었습니다. 위의 PDF 필기로 전환하세요.'
                    : _pdfVariants.isNotEmpty
                    ? '이 원본에 저장된 PDF 필기 버전이 있습니다.'
                    : preview != null
                    ? '미리보기 PDF가 준비되었습니다. PDF 필기를 시작하면 이 PDF로 필기 버전을 만듭니다.'
                    : 'PDF가 아직 없습니다.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _canSearchPdfText =>
      _liveNote &&
      _pdfMode &&
      !_busy &&
      !_dirty &&
      !_annotationLoadFailed &&
      !_incomingAnnotationAvailable &&
      _transitionOperation == null &&
      _annotationHeads.length <= 1 &&
      _annotation != null &&
      _editorKey.currentState != null;

  Future<void> _showPdfTextSearch() async {
    final editor = _editorKey.currentState;
    final edition = _edition;
    final preview = _selectedPdf;
    final annotation = _annotation;
    if (!_canSearchPdfText ||
        editor == null ||
        edition == null ||
        preview == null ||
        annotation == null ||
        annotation.bindingId != preview.bindingId ||
        annotation.editionRevisionId != edition.revision.revisionId ||
        preview.sourceRevisionId != edition.revision.revisionId) {
      return;
    }
    final core = editor.coreInfo;
    final generation = _generation;
    final repository = widget.repository;
    final revision = annotation.revision?.revisionId;
    bool current() =>
        _current(generation) &&
        _canSearchPdfText &&
        identical(widget.repository, repository) &&
        identical(_edition, edition) &&
        identical(_selectedPdf, preview) &&
        identical(_annotation, annotation) &&
        identical(_editorKey.currentState, editor) &&
        identical(editor.coreInfo, core) &&
        annotation.revision?.revisionId == revision;

    Future<bool> storedCurrent() async {
      if (!current()) return false;
      final heads = await repository.heads(annotation.bindingId);
      return current() &&
          (revision == null
              ? heads.isEmpty
              : heads.singleOrNull?.revisionId == revision);
    }

    final hit = await showDialog<PdfTextSearchHit>(
      context: context,
      builder: (_) => PdfTextSearchDialog(
        search: (query, active) async {
          if (!active() || !await storedCurrent() || !active()) return null;
          final result = await PdfImportPreparation.searchBoundPdfText(
            core,
            query,
            pdfSha256: preview.pdfSha256,
            isCurrent: () => active() && current(),
          );
          return active() && await storedCurrent() && active() ? result : null;
        },
      ),
    );
    if (hit == null || !current()) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!await storedCurrent()) return;
    if (editor.revealPage(hit.pageId, background: hit.destination.background)) {
      await _rememberView();
    } else {
      setState(() => _notice = '연결된 필기 페이지를 표시할 수 없습니다.');
    }
  }

  NoteLink? get currentPageLink {
    final editor = _editorKey.currentState;
    final edition = _edition;
    final preview = _selectedPdf;
    final annotation = _annotation;
    if (!_canSearchPdfText ||
        editor == null ||
        edition == null ||
        preview == null ||
        annotation == null ||
        !_liveNote ||
        annotation.bindingId != preview.bindingId ||
        annotation.editionRevisionId != edition.revision.revisionId ||
        preview.sourceRevisionId != edition.revision.revisionId) {
      return null;
    }
    final pages = editor.coreInfo.pages;
    final index = editor.currentPageIndex;
    if (index < 0 || index >= pages.length) return null;
    final pageId = pages[index].pageId;
    if (pages.where((page) => page.pageId == pageId).singleOrNull == null) {
      return null;
    }
    return NoteLink.officePage(widget.note.id, (
      sourceRevisionId: edition.revision.revisionId,
      pdfBindingId: preview.bindingId,
      pageId: pageId,
    ));
  }

  Future<NoteLink?> saveCurrentPageLink() async {
    final link = currentPageLink;
    final target = link?.officePageTarget;
    if (link == null || target == null) return null;
    final generation = _generation;
    final repository = widget.repository;
    final editor = _editorKey.currentState;
    bool current() =>
        _current(generation) &&
        identical(_editorKey.currentState, editor) &&
        currentPageLink?.officePageTarget == target;
    await _saveAnnotations();
    if (!current()) return null;
    await OfficeWorkspace.preparePageLink(
      repository: repository,
      noteId: link.noteId,
      target: target,
    );
    return current() ? link : null;
  }

  Widget _pdfEditor() {
    final annotation = _annotation;
    if (annotation == null)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('서로 다른 PDF 필기가 있습니다. 열 버전을 선택하세요.'),
              for (var i = 0; i < _annotationHeads.length; i++)
                TextButton(
                  key: ValueKey(
                    'office-annotation-${_annotationHeads[i].revisionId}',
                  ),
                  onPressed: _switching
                      ? null
                      : () => unawaited(
                          _run(
                            () => _openPdf(
                              annotationRevisionId:
                                  _annotationHeads[i].revisionId,
                            ),
                          ),
                        ),
                  child: Text('필기 버전 ${i + 1}'),
                ),
            ],
          ),
        ),
      );
    final generation = _generation;
    bool current() =>
        _current(generation) && identical(_annotation, annotation);
    return Editor(
      key: _editorKey,
      path: annotation.workingPath,
      customTitle: '${widget.note.title} · PDF 필기',
      showDocumentHeader: widget.showBackButton,
      pdfPath: annotation.revision == null ? _pdfPath : null,
      initialPdfBaselinePageId: annotation.revision == null
          ? (pageIndex) =>
                officePdfBaselinePageId(annotation.bindingId, pageIndex)
          : null,
      loadSnapshot: () async {
        try {
          final prepared = current() ? _incomingAnnotationSnapshot : null;
          if (prepared != null) _incomingAnnotationSnapshot = null;
          final core = prepared ?? await annotation.load();
          final pageId = _viewPageId;
          if (current() && pageId != null) {
            final index = core.pages.indexWhere(
              (page) => page.pageId == pageId,
            );
            core.initialPageIndex = index < 0 ? 0 : index;
          }
          return core;
        } catch (_) {
          final originalReveal = _originalPageReveal;
          if (current() &&
              originalReveal != null &&
              identical(originalReveal.annotation, annotation)) {
            _abortOriginalPageReveal(
              originalReveal,
              '미리보기와 연결된 필기 판본을 열 수 없습니다.',
            );
            rethrow;
          }
          if (current() && annotation.revision != null) {
            setState(() {
              _annotationLoadFailed = true;
              _editorBusy = false;
              if (_restoringView) {
                _restoringView = false;
                _pdfMode = false;
                _annotation = null;
                _notice = '이전 PDF 필기 화면을 복원하지 못했습니다. 원본에서 필기 버전을 선택하세요.';
                _error = null;
              } else {
                _error = 'PDF 필기를 열 수 없습니다. 원본과 저장된 필기 파일은 보존되어 있습니다.';
              }
            });
            _report();
            final reveal = _pageLinkReveal;
            if (reveal != null && identical(reveal.annotation, annotation)) {
              _finishPageLink(
                reveal.request,
                error: const FormatException('PDF 필기 판본을 열 수 없습니다.'),
              );
            }
          }
          rethrow;
        }
      },
      onSaveSnapshot: (core, page) async {
        if (!current()) throw StateError('이전 PDF의 늦은 저장을 거부했습니다.');
        await annotation.saveSnapshot(core, page);
      },
      onDirtyChanged: (dirty) {
        if (current()) {
          if (_editorDirty != dirty) setState(() => _editorDirty = dirty);
          _report();
        }
      },
      onBusyChanged: (busy) {
        if (current()) {
          _editorBusy = busy;
          _report();
          if (mounted) setState(() {});
        }
      },
      onLoaded: (core) {
        if (current()) {
          if (annotation.revision == null && _viewPageId != null) {
            final index = core.pages.indexWhere(
              (page) => page.pageId == _viewPageId,
            );
            if (index >= 0) core.initialPageIndex = index;
          }
          _restoringView = false;
          _editorBusy = false;
          _annotationLoadFailed = false;
          _report();
          setState(() {});
          final reveal = _pageLinkReveal;
          final originalReveal = _originalPageReveal;
          if (reveal != null && identical(reveal.annotation, annotation)) {
            unawaited(
              _revealLoadedPageLink(
                reveal.request,
                annotation,
                core,
                generation,
              ),
            );
          } else if (originalReveal != null &&
              identical(originalReveal.annotation, annotation)) {
            unawaited(
              _revealLoadedOriginalPage(originalReveal, core, generation),
            );
          } else {
            unawaited(_run(_refreshAnnotationView));
          }
        }
      },
      onCancelImport: () async {
        if (!current()) return;
        final originalReveal = _originalPageReveal;
        if (originalReveal != null &&
            identical(originalReveal.annotation, annotation)) {
          _abortOriginalPageReveal(originalReveal, 'PDF 필기 열기를 취소했습니다.');
          return;
        }
        final reveal = _pageLinkReveal;
        setState(() {
          _pdfMode = false;
          _restoringView = false;
          _annotation = null;
          _editorDirty = false;
          _editorBusy = false;
          _editorKey = GlobalKey();
        });
        _report();
        if (reveal != null && identical(reveal.annotation, annotation)) {
          _finishPageLink(
            reveal.request,
            error: const FormatException('PDF 열기가 취소됐습니다.'),
          );
        }
        await _rememberView();
      },
      onBack: () => unawaited(_run(_back)),
    );
  }

  Widget _recoveryCard(
    OfficeEditRecoveryEntry entry, {
    bool preserved = false,
  }) {
    final editing = entry.resumableStage == OfficeEditRecoveryStage.started;
    return Card(
      key: ValueKey(
        '${preserved ? 'office-preserved-recovery' : 'office-recovery'}-${entry.sessionId}',
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              editing ? '이전에 마치지 못한 원본 편집이 있습니다.' : '저장을 마치지 못한 원본과 PDF가 있습니다.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton(
                  key: ValueKey(
                    'office-recovery-${editing ? 'resume' : 'save'}-${entry.sessionId}',
                  ),
                  onPressed:
                      _busy ||
                          !_liveNote ||
                          !entry.canResume ||
                          _pendingNative != null
                      ? null
                      : () => unawaited(
                          _run(
                            () => _runRecovery(() => _continueRecovery(entry)),
                          ),
                        ),
                  child: Text(editing ? '이어 편집' : '이어 저장'),
                ),
                if (!preserved)
                  TextButton(
                    key: ValueKey(
                      'office-recovery-preserve-${entry.sessionId}',
                    ),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _run(
                              () =>
                                  _runRecovery(() => _preserveRecovery(entry)),
                            ),
                          ),
                    child: const Text('파일 보관'),
                  ),
              ],
            ),
            if (preserved) ...[
              const SizedBox(height: 8),
              SelectableText(
                entry.sourcePath ?? entry.workingPath,
                style: const TextStyle(fontSize: 11),
              ),
              if (entry.pdfPath != null)
                SelectableText(
                  entry.pdfPath!,
                  style: const TextStyle(fontSize: 11),
                ),
            ],
            if (!entry.canResume) const Text('문서의 원본 연결이 바뀌어 파일 보관만 가능합니다.'),
          ],
        ),
      ),
    );
  }

  Widget _recoveryPanel() {
    final entries = _recoveries
        .where(
          (entry) =>
              entry.stage != OfficeEditRecoveryStage.completed &&
              entry.stage != OfficeEditRecoveryStage.unchanged,
        )
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final preserved = entries
        .where((entry) => entry.stage == OfficeEditRecoveryStage.preserved)
        .toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final entry in entries.where(
              (entry) => entry.stage != OfficeEditRecoveryStage.preserved,
            ))
              _recoveryCard(entry),
            if (preserved.isNotEmpty)
              ExpansionTile(
                title: Text('보관한 편집 작업 (${preserved.length})'),
                children: [
                  for (final entry in preserved)
                    _recoveryCard(entry, preserved: true),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _interactiveStatus() {
    final editing = _interactiveEditing;
    if (editing == null || !_current(editing.generation)) {
      return const SizedBox.shrink();
    }
    final cancelling = editing.cancellationRequested;
    final message = editing.publicationStarted
        ? '편집 내용을 문서에 저장하고 있습니다.'
        : cancelling
        ? editing.resultReceived
              ? '앱에 반영하지 않고 편집 결과를 보관하고 있습니다.'
              : '앱 반영을 취소했습니다. 편집창을 닫아주세요.'
        : editing.resultReceived
        ? '편집 결과를 확인하고 있습니다.'
        : 'Office 편집창에서 저장한 뒤 닫아주세요.';
    return Padding(
      key: const ValueKey('office-interactive-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(message),
          if (!editing.publicationStarted)
            TextButton(
              key: const ValueKey('office-interactive-cancel'),
              onPressed: cancelling
                  ? null
                  : () => unawaited(_run(_cancelInteractiveEditing)),
              child: const Text('앱 반영 취소'),
            ),
        ],
      ),
    );
  }

  Widget _modeSelector() => SegmentedButton<bool>(
    segments: [
      const ButtonSegment(value: false, label: Text('원본')),
      ButtonSegment(
        value: true,
        label: const Text('PDF 필기'),
        enabled: _canPreview,
      ),
    ],
    selected: {_pdfMode},
    onSelectionChanged: _busy
        ? null
        : (values) {
            if (values.single) {
              unawaited(_run(_startPdfPreview));
            } else {
              unawaited(
                _run(() async {
                  await _saveAnnotations();
                  if (!mounted) return;
                  _captureViewPage();
                  setState(() => _pdfMode = false);
                  await _rememberView();
                }),
              );
            }
          },
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final editions = Row(
              children: [
                if (widget.showBackButton)
                  IconButton(
                    tooltip: '문서 목록으로',
                    onPressed: _busy ? null : () => unawaited(_run(_back)),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(child: _editionSelector()),
              ],
            );
            final modes = _edition == null ? null : _modeSelector();
            final search = _pdfMode
                ? IconButton(
                    key: const ValueKey('office-pdf-text-search'),
                    tooltip: 'PDF 본문 검색',
                    onPressed: _canSearchPdfText
                        ? () => unawaited(_run(_showPdfTextSearch))
                        : null,
                    icon: const Icon(Icons.search),
                  )
                : null;
            if (!_useWindows && constraints.maxWidth < 440 && modes != null) {
              return Column(
                children: [
                  editions,
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: modes,
                        ),
                      ),
                      ?search,
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, row) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: _useWindows && row.maxWidth < 620
                            ? 620
                            : row.maxWidth,
                        child: Row(
                          children: [
                            Expanded(child: editions),
                            if (modes != null) ...[
                              const SizedBox(width: 12),
                              modes,
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ?search,
              ],
            );
          },
        ),
      ),
      if (_pdfVariants.length > 1)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _pdfVariantSelector(),
        ),
      if (_busy) const LinearProgressIndicator(),
      if (_previewOperation != null && !_pdfMode)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'PDF 필기를 준비하고 있습니다…',
            key: ValueKey('office-pdf-preparing'),
          ),
        ),
      _interactiveStatus(),
      _recoveryPanel(),
      if (_sourceHeads.length > 1)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('서로 다른 원본 버전이 있습니다. 버전을 선택하세요.'),
        ),
      if (_notice != null)
        Padding(padding: const EdgeInsets.all(8), child: Text(_notice!)),
      if (_originalPageConflict case final conflict?
          when _matchesShownOriginalPage(conflict.page))
        TextButton.icon(
          key: const ValueKey('office-open-annotation-conflict'),
          onPressed: _busy
              ? null
              : () => unawaited(
                  _run(() => _chooseOriginalPageAnnotation(conflict)),
                ),
          icon: const Icon(Icons.layers_outlined),
          label: const Text('서로 다른 PDF 필기가 있습니다. 필기 버전 선택'),
        ),
      if (_pdfMode && _incomingAnnotationAvailable)
        TextButton.icon(
          key: const ValueKey('office-incoming-annotation'),
          onPressed: _busy
              ? null
              : () => unawaited(_run(() => _openPdf(reloadingIncoming: true))),
          icon: const Icon(Icons.sync),
          label: Text(
            _annotationHeads.length > 1 ? '동기화된 필기 버전 선택' : '동기화된 필기 보기',
          ),
        ),
      if (_error != null)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(_error!),
                if (_pendingNative != null) ...[
                  const Text('편집 파일은 기기에 남아 있습니다. 원본 저장소는 덮어쓰지 않았습니다.'),
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_run(_commitPending)),
                        child: const Text('저장 재시도'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _run(() async {
                                  final generation = _generation;
                                  await _runRecovery(_preservePending);
                                  if (_current(generation)) await _back();
                                }),
                              ),
                        child: const Text('파일을 보관하고 목록으로'),
                      ),
                    ],
                  ),
                ],
                if (_recoveryPath != null)
                  SelectableText(
                    _recoveryPath!,
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      Expanded(
        child: AbsorbPointer(
          absorbing:
              _switching ||
              _nativeOperation != null ||
              _previewOperation != null ||
              _originalPreviewOperation != null ||
              _recoveryOperation != null ||
              _commitOperation != null ||
              (_originalPageReveal != null && !_editorBusy),
          child: ExcludeFocus(
            excluding: _originalPageReveal != null && !_editorBusy,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _edition == null
                ? const Center(child: Text('위에서 원본 버전을 선택하세요.'))
                : _pdfMode
                ? _pdfEditor()
                : _originalInfo(_edition!),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _clearIncomingAnnotation();
    final session = _windowsSession;
    if (session != null) unawaited(session.close());
    final interactive = _interactiveEditing;
    if (interactive != null) unawaited(interactive.abandon());
    _interactiveEditing = null;
    _generation++;
    _refreshTimer?.cancel();
    unawaited(_changes?.cancel());
    super.dispose();
  }
}

class _PendingNative {
  final OfficeEditSession session;
  final AndroidOfficeEditResult result;
  final String sessionId;
  final int generation;
  final String workingPath;
  final OfficeEditRecoveryStore recovery;
  final OfficeDocumentStore documents;
  OfficePreparedEdition? preparedEdition;
  new(
    this.session,
    this.result,
    this.sessionId,
    this.generation,
    this.workingPath,
    this.recovery,
    this.documents, {
    this.preparedEdition,
  });
}

class _OriginalPreviewData {
  final String sourceRevisionId;
  final String sourceSha256;
  final Uint8List pdfBytes;
  final String pdfSha256;
  final int pageCount;
  const new(
    this.sourceRevisionId,
    this.sourceSha256,
    this.pdfBytes,
    this.pdfSha256,
    this.pageCount,
  );
}

class _WindowsInteractiveEditing {
  new(
    this.captured,
    this.id,
    this.generation,
    this.workingPath,
    this.engine,
    this.recovery,
    this.documents,
  );

  final OfficeEditSession captured;
  final String id;
  final int generation;
  final String workingPath;
  final WindowsOfficeEngine engine;
  final OfficeEditRecoveryStore recovery;
  final OfficeDocumentStore documents;
  WindowsOfficeInteractiveSession? native;
  var _cancellationRequested = false;
  var resultReceived = false;
  var publicationStarted = false;

  bool get cancellationRequested =>
      _cancellationRequested || native?.cancellationRequested == true;

  Future<void> cancel() {
    if (publicationStarted) return Future.value();
    _cancellationRequested = true;
    return native?.cancel() ?? Future.value();
  }

  Future<void> abandon() {
    if (publicationStarted) return Future.value();
    _cancellationRequested = true;
    return native?.dispose() ?? Future.value();
  }
}

class _WindowsEditingSession {
  new(
    this.captured,
    this.id,
    this.generation,
    this.workingPath,
    this.snapshot,
    this.engine,
  );
  final OfficeEditSession captured;
  final String id;
  final int generation;
  final String workingPath;
  final WindowsOfficeSnapshot snapshot;
  final WindowsOfficeEngine engine;
  WindowsOfficeEditResult? pendingResult;
  String? pendingSignature;
  OfficeEdition? committedEdition;
  WindowsOfficePreview? previewLease;
  String? previewSignature;
  WindowsOfficePreview? retiredPreview;
  Future<void>? outputOperation;
  var closed = false;

  Future<void> close() async {
    closed = true;
    await outputOperation;
    await retiredPreview?.dispose();
    await previewLease?.dispose();
  }
}
